import Foundation
import MarqueeCore
import OSLog
import UIKit

/// Hands one 64 MB slice of a download at a time to iOS, which fetches it while the app is suspended
/// or closed and wakes the app when it lands. Each slice is copied into the part file at its offset
/// and flushed, so every landed slice is kept whatever happens next.
///
/// iOS's hand-over of a finished background file can fail with `NSURLErrorCannotCreateFile` (-3000)
/// for no reason the app can see; Stashy measured it on every slice of every file on one iOS build.
/// The first one switches the transport off for that iOS version, so a broken build costs one slice.
final class BackgroundTransfer: Sendable {
    /// What iOS fetches: a range of one download's part file. Kept in the task's description, so a
    /// slice that lands after a relaunch still finds its file.
    struct Slice: Codable, Sendable, Hashable {
        let id: String
        let part: String
        let lower: Int64
        let upper: Int64

        var range: Range<Int64> { lower..<upper }
    }

    enum Result: Sendable {
        /// `written` is flushed into the part file; `length` is the file's, when the server said it.
        case saved(Slice, written: Range<Int64>, length: Int64?)
        case notReady(Slice)
        case failed(Slice, String)
        case stopped(Slice)
    }

    static let identifier = "com.nphil.marquee.downloads"

    /// The system's completion handler from a background launch, called once the session's events are
    /// delivered so iOS can suspend the app again.
    @MainActor static var completionHandler: (() -> Void)?

    private let session: URLSession?

    /// Off under the UI tests' fake server, which iOS's transfer daemon cannot reach, and on an iOS
    /// version that refused a hand-over.
    init(onResult: @escaping @Sendable (Result) -> Void) {
        guard !FakePlex.isActive, UserDefaults.standard.string(forKey: Self.brokenKey) != Self.systemVersion else {
            session = nil
            return
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let delegate = Delegate(onResult: onResult) {
            UserDefaults.standard.set(Self.systemVersion, forKey: Self.brokenKey)
        }
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    var isAvailable: Bool { session != nil }

    func start(_ slice: Slice, url: URL, headers: [String: String], cellular: Bool) {
        guard let session else { return }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(slice.lower)-\(slice.upper - 1)", forHTTPHeaderField: "Range")
        request.allowsCellularAccess = cellular
        let task = session.downloadTask(with: request)
        task.taskDescription = (try? JSONEncoder().encode(slice)).map { String(decoding: $0, as: UTF8.self) }
        task.countOfBytesClientExpectsToReceive = slice.upper - slice.lower
        task.resume()
    }

    /// The slices iOS holds now, so the foreground leaves their bytes alone until they land.
    func running() async -> [Slice] {
        guard let session else { return [] }
        return await session.allTasks.compactMap { Self.slice(of: $0) }
    }

    /// Stops every slice of a download that is removed or paused.
    func cancel(id: String) async {
        guard let session else { return }
        for task in await session.allTasks where Self.slice(of: task)?.id == id { task.cancel() }
    }

    fileprivate static func slice(of task: URLSessionTask) -> Slice? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Slice.self, from: Data($0.utf8)) }
    }

    private static let brokenKey = "marquee.downloads.backgroundBroken"
    private static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        private let onResult: @Sendable (Result) -> Void
        private let refused: @Sendable () -> Void
        private let log = Logger(subsystem: "com.nphil.marquee", category: "downloads")

        init(onResult: @escaping @Sendable (Result) -> Void, refused: @escaping @Sendable () -> Void) {
            self.onResult = onResult
            self.refused = refused
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let slice = BackgroundTransfer.slice(of: downloadTask) else { return }
            let http = downloadTask.response as? HTTPURLResponse
            let reply = RangeReply.judge(
                status: http?.statusCode ?? 0,
                contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.map(\.expectedContentLength).flatMap { $0 >= 0 ? $0 : nil },
                retryAfter: nil,
                requested: slice.range
            )
            switch reply {
            case .partial(let length):
                onResult(save(location, into: slice, at: slice.lower, limit: slice.upper, length: length))
            case .whole(let length):
                onResult(save(location, into: slice, at: 0, limit: nil, length: length))
            case .notReady:
                onResult(.notReady(slice))
            case .failed(let status):
                onResult(.failed(slice, "The server answered \(status)."))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // A success was reported from didFinishDownloadingTo.
            guard let error, let slice = BackgroundTransfer.slice(of: task) else { return }
            let code = (error as NSError).code
            if code == NSURLErrorCancelled {
                onResult(.stopped(slice))
                return
            }
            if code == NSURLErrorCannotCreateFile {
                log.error("dl-background refused code=-3000; transport off for this iOS version")
                refused()
            }
            onResult(.failed(slice, error.localizedDescription))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor in
                BackgroundTransfer.completionHandler?()
                BackgroundTransfer.completionHandler = nil
            }
        }

        /// Copies the landed file into the part at `offset`, up to `limit`, and flushes it.
        private func save(_ location: URL, into slice: Slice, at offset: Int64, limit: Int64?, length: Int64?) -> Result {
            let input = open(location.path(percentEncoded: false), O_RDONLY)
            let output = open(slice.part, O_WRONLY | O_CREAT, 0o644)
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
                    if wrote < 0 {
                        if errno == EINTR { continue }
                        return .failed(slice, errno == ENOSPC ? "The iPhone is out of space." : "The download could not be saved.")
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
