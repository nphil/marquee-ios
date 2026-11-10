import Foundation
import MarqueeCore
import Synchronization

/// Bytes arriving for each download, counted where they are written and read by the center once a
/// second for the progress bars and the speed.
final class TransferMeter: Sendable {
    private struct Counts {
        /// Every byte written since launch, for the speed.
        var moved: [String: Int64] = [:]
        /// Written but not yet in the record's flushed ranges.
        var pending: [String: Int64] = [:]
    }

    private let counts = Mutex(Counts())

    func add(_ bytes: Int64, for id: String) {
        counts.withLock {
            $0.moved[id, default: 0] += bytes
            $0.pending[id, default: 0] += bytes
        }
    }

    /// The record now holds `bytes` of what was counted as pending.
    func commit(_ bytes: Int64, for id: String) {
        counts.withLock { $0.pending[id] = max(0, ($0.pending[id] ?? 0) - bytes) }
    }

    /// Drops what a stopped transfer wrote without flushing.
    func clearPending(for id: String) {
        counts.withLock { $0.pending[id] = nil }
    }

    func moved(_ id: String) -> Int64 {
        counts.withLock { $0.moved[id] ?? 0 }
    }

    func pending(_ id: String) -> Int64 {
        counts.withLock { $0.pending[id] ?? 0 }
    }
}

/// Fetches byte ranges of a download in the foreground, each written into the part file at its own
/// offset as it arrives and flushed before the range counts as saved. Nothing passes through memory
/// beyond one network packet, and an interrupted range keeps every byte that reached the disk.
final class RangeFetcher: Sendable {
    /// What one request left on disk.
    struct Outcome: Sendable {
        /// The bytes written and flushed; empty when nothing was.
        var written: Range<Int64>
        /// The server's answer; nil when none arrived.
        var reply: RangeReply?
        var error: (any Error)?
    }

    let meter: TransferMeter
    private let session: URLSession
    private let delegate: Delegate

    init(meter: TransferMeter) {
        self.meter = meter
        let configuration = URLSessionConfiguration.default
        // A video's bytes go to its part file; a URL cache would keep a second copy of each range.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        FakePlex.install(into: configuration)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        delegate = Delegate(meter: meter)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    /// Asks for `range` of `url` and writes what comes into `file`: the range at its offset, or, from a
    /// server that sends the whole file instead, everything from the first byte.
    func fetch(_ url: URL, headers: [String: String], range: Range<Int64>, into file: URL, id: String, cellular: Bool) async -> Outcome {
        let nothing = range.lowerBound..<range.lowerBound
        let descriptor = open(file.path(percentEncoded: false), O_WRONLY)
        guard descriptor >= 0 else {
            return Outcome(written: nothing, error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.allowsCellularAccess = cellular
        request.timeoutInterval = 30
        let task = session.dataTask(with: request)
        let cancellation = Mutex((registered: false, cancelled: false))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.add(Job(id: id, descriptor: descriptor, requested: range, start: range.lowerBound, offset: range.lowerBound, continuation: continuation), for: task.taskIdentifier)
                cancellation.withLock { state in
                    state.registered = true
                    if state.cancelled { task.cancel() } else { task.resume() }
                }
            }
        } onCancel: {
            cancellation.withLock { state in
                state.cancelled = true
                if state.registered { task.cancel() }
            }
        }
    }

    private struct Job: Sendable {
        let id: String
        let descriptor: Int32
        let requested: Range<Int64>
        /// Where writing began, and the next byte's place.
        var start: Int64
        var offset: Int64
        /// Writing stops here; nil for a whole file.
        var limit: Int64?
        var reply: RangeReply?
        var writeError: POSIXError?
        let continuation: CheckedContinuation<Outcome, Never>

        init(id: String, descriptor: Int32, requested: Range<Int64>, start: Int64, offset: Int64, continuation: CheckedContinuation<Outcome, Never>) {
            self.id = id
            self.descriptor = descriptor
            self.requested = requested
            self.start = start
            self.offset = offset
            limit = requested.upperBound
            self.continuation = continuation
        }
    }

    /// The `URLSessionDataDelegate` conformance must stay declared: URLSession checks for the data
    /// callback by selector, and without the protocol it never calls it (Stashy lost a debugging round
    /// to a transfer that finished without error and wrote nothing).
    private final class Delegate: NSObject, URLSessionDataDelegate, Sendable {
        private let jobs = Mutex<[Int: Job]>([:])
        private let meter: TransferMeter

        init(meter: TransferMeter) {
            self.meter = meter
        }

        func add(_ job: Job, for task: Int) {
            jobs.withLock { $0[task] = job }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let http = response as? HTTPURLResponse
            let allowed = jobs.withLock { jobs -> Bool in
                guard var job = jobs[dataTask.taskIdentifier] else { return false }
                let reply = RangeReply.judge(
                    status: http?.statusCode ?? 0,
                    contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: response.expectedContentLength >= 0 ? response.expectedContentLength : nil,
                    retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                    requested: job.requested
                )
                job.reply = reply
                var allowed = true
                switch reply {
                case .partial:
                    break
                case .whole:
                    job.start = 0
                    job.offset = 0
                    job.limit = nil
                case .notReady, .failed:
                    allowed = false
                }
                jobs[dataTask.taskIdentifier] = job
                return allowed
            }
            completionHandler(allowed ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let job = jobs.withLock({ $0[dataTask.taskIdentifier] }), job.writeError == nil else { return }
            let room = job.limit.map { max(0, $0 - job.offset) } ?? Int64(data.count)
            let count = Int(min(Int64(data.count), room))
            guard count > 0 else { return }
            let failure = data.withUnsafeBytes { Self.write(job.descriptor, UnsafeRawBufferPointer(rebasing: $0.prefix(count)), at: job.offset) }
            jobs.withLock {
                if failure == nil { $0[dataTask.taskIdentifier]?.offset += Int64(count) }
                $0[dataTask.taskIdentifier]?.writeError = failure
            }
            if failure == nil {
                meter.add(Int64(count), for: job.id)
            } else {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let job = jobs.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
            let flushed = fsync(job.descriptor) == 0
            let flushError = flushed ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(job.descriptor)
            let written = flushed ? job.start..<job.offset : job.start..<job.start
            job.continuation.resume(returning: Outcome(written: written, reply: job.reply, error: job.writeError ?? flushError ?? error))
        }

        /// Nil once every byte is written.
        private static func write(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer, at offset: Int64) -> POSIXError? {
            guard let base = buffer.baseAddress else { return nil }
            var done = 0
            while done < buffer.count {
                let count = pwrite(descriptor, base + done, buffer.count - done, off_t(offset) + off_t(done))
                if count <= 0 {
                    if count < 0 && errno == EINTR { continue }
                    return POSIXError(count == 0 ? .EIO : (POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
                done += count
            }
            return nil
        }
    }
}
