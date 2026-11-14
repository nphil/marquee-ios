import Foundation
import MarqueeCore
import OSLog
import Synchronization
import UIKit

/// Hands one 64 MB slice of a download at a time to iOS, which fetches it while the app is suspended
/// or closed and wakes the app when it lands. Each slice is copied into the part file at its offset
/// and flushed, so every landed slice is kept whatever happens next. A streamed conversion hands over
/// its next segments instead, each kept beside the part file until the app appends it.
///
/// iOS's hand-over of a finished background file can fail with `NSURLErrorCannotCreateFile` (-3000)
/// for no reason the app can see; Stashy measured it on every slice of every file on one iOS build.
/// The first one switches the transport off for that iOS version, so a broken build costs one slice.
final class BackgroundTransfer: Sendable {
    /// What iOS fetches: a range of one download's part file. Kept in the task's description, so a
    /// slice that lands after a relaunch still finds its file.
    struct Slice: Codable, Sendable, Hashable {
        let id: String
        /// Relative to Application Support, whose container path may change after relaunch.
        let part: String
        let lower: Int64
        let upper: Int64
        /// Set for a segment of a streamed conversion, which lands beside the part file as a piece
        /// (`StreamedFile`); `upper - lower` is then about its size.
        var segment: Segment?

        struct Segment: Codable, Sendable, Hashable {
            let number: Int
            /// Seconds into the title.
            let end: Double
        }

        var range: Range<Int64> { lower..<upper }
    }

    enum Result: Sendable {
        /// `written` is flushed into the part file; `length` is the file's, when the server said it.
        case saved(Slice, written: Range<Int64>, length: Int64?)
        case notReady(Slice, retryAfter: Int)
        /// A connection failure: the slice is tried again later. `dropped` is the address when the failure
        /// was its own, so the next slice goes to one that answers.
        case interrupted(Slice, dropped: URL?)
        case failed(Slice, String)
        /// The server dropped the streamed conversion's session, so the segments after it fail too.
        case expired(Slice)
        case stopped(Slice)
    }

    static let identifier = "com.nphil.marquee.downloads"

    /// The system's completion handler from a background launch, called once the session's events are
    /// delivered so iOS can suspend the app again.
    @MainActor static var completionHandler: (() -> Void)?

    private let session: URLSession?

    /// Off under the UI tests' fake server, which iOS's transfer daemon cannot reach, and on an iOS
    /// version that refused a hand-over.
    init(onResult: @escaping @Sendable (Result) async -> Void) {
        guard !FakePlex.isActive, UserDefaults.standard.string(forKey: Self.brokenKey) != Self.systemVersion else {
            session = nil
            return
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // A streamed conversion's segments go one at a time, in order: PMS 1.43.5 moves its transcode
        // to a segment asked for far ahead.
        configuration.httpMaximumConnectionsPerHost = 1
        let delegate = Delegate(onResult: onResult) {
            UserDefaults.standard.set(Self.systemVersion, forKey: Self.brokenKey)
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    var isAvailable: Bool {
        session != nil && UserDefaults.standard.string(forKey: Self.brokenKey) != Self.systemVersion
    }

    /// What a slice's part path is relative to.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func start(_ slice: Slice, url: URL, headers: [String: String], cellular: Bool, after delay: TimeInterval = 0) {
        guard isAvailable, let session else { return }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if slice.segment == nil { request.setValue("bytes=\(slice.lower)-\(slice.upper - 1)", forHTTPHeaderField: "Range") }
        request.allowsCellularAccess = cellular
        let task = session.downloadTask(with: request)
        task.taskDescription = (try? JSONEncoder().encode(slice)).map { String(decoding: $0, as: UTF8.self) }
        task.countOfBytesClientExpectsToReceive = slice.upper - slice.lower
        // iOS holds the task until then, with the app suspended.
        if delay > 0 { task.earliestBeginDate = Date.now.addingTimeInterval(delay) }
        task.resume()
    }

    /// The slices iOS holds now, so the foreground leaves their bytes alone until they land.
    func running() async -> [Slice] {
        guard let session else { return [] }
        return await session.allTasks.compactMap { Self.slice(of: $0) }
    }

    /// Stops every slice of a download that is removed or paused.
    func cancel(part: String) async {
        guard let session else { return }
        for task in await session.allTasks where Self.slice(of: task)?.part == part { task.cancel() }
    }

    /// Stops the slices iOS has not begun to receive, so the app can fetch them itself.
    func cancelUnstarted() async {
        guard let session else { return }
        for task in await session.allTasks where task.countOfBytesReceived == 0 && Self.slice(of: task) != nil { task.cancel() }
    }

    fileprivate static func slice(of task: URLSessionTask) -> Slice? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Slice.self, from: Data($0.utf8)) }
    }

    private static let brokenKey = "marquee.downloads.backgroundBroken"
    private static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        private let onResult: @Sendable (Result) async -> Void
        private let delivery = Mutex<Task<Void, Never>?>(nil)
        private let refused: @Sendable () -> Void
        private let log = Logger(subsystem: "com.nphil.marquee", category: "downloads")

        init(onResult: @escaping @Sendable (Result) async -> Void, refused: @escaping @Sendable () -> Void) {
            self.onResult = onResult
            self.refused = refused
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let slice = BackgroundTransfer.slice(of: downloadTask) else { return }
            let http = downloadTask.response as? HTTPURLResponse
            if let segment = slice.segment {
                deliver(keep(location, of: slice, segment: segment, status: http?.statusCode ?? 0))
                return
            }
            let reply = RangeReply.judge(
                status: http?.statusCode ?? 0,
                contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.map(\.expectedContentLength).flatMap { $0 >= 0 ? $0 : nil },
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                requested: slice.range
            )
            switch reply {
            case .partial(let length):
                deliver(save(location, into: slice, at: slice.lower, limit: slice.upper, length: length))
            case .whole(let length):
                deliver(save(location, into: slice, at: 0, limit: nil, length: length))
            case .notReady(let retryAfter):
                deliver(.notReady(slice, retryAfter: retryAfter))
            case .failed(let status):
                deliver(TransferPlan.isTransient(TransferStatusError(status: status)) ? .interrupted(slice, dropped: nil) : .failed(slice, "The server answered \(status)."))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // A success was reported from didFinishDownloadingTo.
            guard let error, let slice = BackgroundTransfer.slice(of: task) else { return }
            let code = (error as NSError).code
            if code == NSURLErrorCancelled {
                deliver(.stopped(slice))
                return
            }
            if code == NSURLErrorCannotCreateFile {
                log.error("dl-background refused code=-3000; transport off for this iOS version")
                refused()
            }
            let dropped = TransferPlan.dropsAddress(error) ? task.originalRequest?.url : nil
            deliver(TransferPlan.isTransient(error) ? .interrupted(slice, dropped: dropped) : .failed(slice, error.localizedDescription))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            enqueue {
                await MainActor.run {
                    BackgroundTransfer.completionHandler?()
                    BackgroundTransfer.completionHandler = nil
                }
            }
        }

        private func deliver(_ result: Result) {
            enqueue { [onResult] in await onResult(result) }
        }

        private func enqueue(_ work: @escaping @Sendable () async -> Void) {
            delivery.withLock { previous in
                let earlier = previous
                previous = Task {
                    await earlier?.value
                    await work()
                }
            }
        }

        /// Moves a landed segment beside the part file as its piece. A dropped session answers 404, and
        /// a segment before its start a placeholder.
        private func keep(_ location: URL, of slice: Slice, segment: Slice.Segment, status: Int) -> Result {
            let length = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if status == 404 || ((200..<300).contains(status) && StreamedFile.isPlaceholder(length)) { return .expired(slice) }
            guard (200..<300).contains(status) else {
                return TransferPlan.isTransient(TransferStatusError(status: status)) ? .interrupted(slice, dropped: nil) : .failed(slice, "The server answered \(status).")
            }
            let part = DownloadStore.file(forPart: slice.part, under: BackgroundTransfer.supportDirectory)
            let piece = part.deletingLastPathComponent().appending(path: StreamedFile.pieceName(of: part, number: segment.number, end: segment.end))
            do {
                try? FileManager.default.removeItem(at: piece)
                try FileManager.default.moveItem(at: location, to: piece)
            } catch {
                return .failed(slice, "The download could not be saved.")
            }
            return .saved(slice, written: 0..<Int64(length), length: nil)
        }

        /// Copies the landed file into the part at `offset`, up to `limit`, and flushes it.
        private func save(_ location: URL, into slice: Slice, at offset: Int64, limit: Int64?, length: Int64?) -> Result {
            let input = open(location.path(percentEncoded: false), O_RDONLY)
            let output = open(DownloadStore.file(forPart: slice.part, under: BackgroundTransfer.supportDirectory).path(percentEncoded: false), O_WRONLY)
            defer {
                if input >= 0 { close(input) }
                if output >= 0 { close(output) }
            }
            guard input >= 0, output >= 0 else { return .failed(slice, "The download's file could not be opened.") }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
            defer { buffer.deallocate() }
            var position = offset
            while limit.map({ position < $0 }) ?? true {
                let want = limit.map { min(Int64(buffer.count), $0 - position) } ?? Int64(buffer.count)
                let count = read(input, buffer.baseAddress, Int(want))
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    return .failed(slice, "The download's file could not be read.")
                }
                var done = 0
                while done < count {
                    let wrote = pwrite(output, buffer.baseAddress! + done, count - done, off_t(position) + off_t(done))
                    if wrote <= 0 {
                        if wrote < 0 && errno == EINTR { continue }
                        return .failed(slice, wrote < 0 && errno == ENOSPC ? "The iPhone is out of space." : "The download could not be saved.")
                    }
                    done += wrote
                }
                position += Int64(count)
            }
            guard fsync(output) == 0 else { return .failed(slice, "The download could not be saved.") }
            return .saved(slice, written: offset..<position, length: length)
        }
    }
}

/// Receives iOS's background launch for the transfer session (MarqueeApp adapts it).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTransfer.identifier else {
            completionHandler()
            return
        }
        BackgroundTransfer.completionHandler = completionHandler
    }
}
