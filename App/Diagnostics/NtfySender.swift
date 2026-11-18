import Foundation
import MarqueeCore

/// Sends the live log to the ntfy topic (DESIGN §8.12). Lines gather for up to ten seconds; a warning or an
/// error sends them within a second. Each message stays under ntfy's 4096-byte limit. Unsent lines wait on
/// disk, up to 1 MB, until the server takes them. Thirty messages at once, then one per ten seconds, stays
/// inside the server's limit of 60 at once and one per five seconds. Confined to the log's queue, which is
/// what makes it safe to hand to that queue's closures.
final class NtfySender: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case off
        case sending(lastSent: Date?)
        /// The last try got no answer, or a 429 or 5xx.
        case retrying(status: Int?)
        /// A 401 or 403: nothing more is sent until the settings change.
        case refused(NtfyAnswer)

        var word: String {
            switch self {
            case .off: "off"
            case .sending: "sending"
            case .retrying: "retrying"
            case .refused: "refused"
            }
        }
    }

    var onState: (@Sendable (State) -> Void)? {
        didSet { onState?(state) }
    }

    private static let maxPending = 1_000_000
    private static let interval: TimeInterval = 10
    private let queue: DispatchQueue
    private let launch: String
    private let session: URLSession
    private let file: URL
    /// Unknown until the settings have said; lines wait meanwhile.
    private var setup: DiagLog.Setup?
    private var pending: [DiagLine] = []
    private var pendingBytes = 0
    private var dropped = 0
    private var writer: FileHandle?
    private var bucket = TokenBucket(capacity: 30, refill: 10, now: Date())
    private var backoff = DiagBackoff()
    private var inFlight = false
    private var paused = false
    private var prompting = false
    private var timer: DispatchSourceTimer?
    private var sequence = 0
    private var waiters: [@Sendable () -> Void] = []
    private var state = State.off {
        didSet {
            guard state != oldValue else { return }
            onState?(state)
            guard state.word != oldValue.word else { return }
            var status: Int?
            if case .retrying(let code) = state { status = code }
            Diag.event(.net, "ntfy.state", ["state": state.word, "status": status, "waiting": pending.count], .notice)
        }
    }

    init(folder: URL, queue: DispatchQueue, launch: String, session: URLSession) {
        self.queue = queue
        self.launch = launch
        self.session = session
        file = folder.appending(path: "pending.queue")
    }

    private var isLive: Bool {
        setup.map { $0.live && $0.config != nil } ?? false
    }

    /// Takes back what an earlier launch could not send.
    func restore() {
        guard let data = try? Data(contentsOf: file) else { return }
        for row in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tab = row.firstIndex(of: "\t"), let raw = Int(row[..<tab]), let level = DiagLevel(rawValue: raw) else { continue }
            let text = String(row[row.index(after: tab)...])
            pending.append(DiagLine(text, level: level))
            pendingBytes += text.utf8.count + 1
        }
    }

    func configure(_ new: DiagLog.Setup) {
        let old = setup
        setup = new
        guard isLive else {
            stopTimer()
            clear()
            state = .off
            return
        }
        // A refusal holds until the settings are saved again or a test reaches the server.
        paused = false
        if old?.config != new.config { backoff = DiagBackoff() }
        switch state {
        case .off, .refused: state = .sending(lastSent: nil)
        case .sending, .retrying: break
        }
        startTimer()
        send()
    }

    func enqueue(_ line: DiagLine) {
        if setup != nil, !isLive { return }
        pending.append(line)
        pendingBytes += line.text.utf8.count + 1
        if pendingBytes > Self.maxPending {
            trim()
        } else {
            persist(line)
        }
        if line.level >= .warning, isLive { prompt() }
    }

    /// Sends now; `done` runs once nothing waits, or nothing more can go.
    func flush(_ done: @escaping @Sendable () -> Void) {
        waiters.append(done)
        send()
    }

    func clear() {
        pending = []
        pendingBytes = 0
        dropped = 0
        try? writer?.close()
        writer = nil
        try? FileManager.default.removeItem(at: file)
        release()
    }

    private func prompt() {
        guard !prompting else { return }
        prompting = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            prompting = false
            send()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.send() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func send() {
        guard !inFlight else { return }
        let now = Date()
        guard isLive, !paused, !pending.isEmpty, let setup, let config = setup.config, backoff.ready(now: now),
              bucket.take(now: now) else { return release() }
        sequence += 1
        var header = "launch=\(launch) seq=\(sequence)"
        if dropped > 0 { header += " dropped=\(dropped)" }
        let limit = DiagPacker.messageLimit - header.utf8.count - 1
        let count = fitting(limit)
        guard let message = DiagPacker.pack(Array(pending.prefix(count)), limit: limit).first else { return release() }
        let request = config.publish(NtfyMessage(
            title: setup.title, text: header + "\n" + message.text,
            priority: NtfyPriority.for(message.level), tags: NtfyPriority.tags(for: message.level)
        ))
        inFlight = true
        NtfyClient.send(request, session: session) { [weak self] outcome in
            guard let self else { return }
            queue.async { self.finished(outcome, count: count) }
        }
    }

    /// How many waiting lines fit one message; at least one, which the packer cuts if it is too long.
    private func fitting(_ limit: Int) -> Int {
        var bytes = 0
        var count = 0
        for line in pending {
            bytes += line.text.utf8.count + (count > 0 ? 1 : 0)
            if bytes > limit, count > 0 { break }
            count += 1
        }
        return count
    }

    private func finished(_ outcome: NtfyClient.Outcome, count: Int) {
        inFlight = false
        let now = Date()
        switch outcome.answer {
        case .accepted:
            backoff.succeeded()
            drop(count)
            dropped = 0
            state = .sending(lastSent: now)
            send()
        case .needsToken, .refused:
            paused = true
            state = .refused(outcome.answer ?? .refused)
            release()
        case .rateLimited, .serverError, nil:
            backoff.failed(status: outcome.status, retryAfter: outcome.retryAfter, now: now)
            state = .retrying(status: outcome.status)
            release()
        case .attachmentRefused, .unexpected:
            // The server will never take this message as it is; the rest still go.
            Diag.event(.net, "ntfy.rejected", ["status": outcome.status, "lines": count], .notice)
            drop(count)
            send()
        }
    }

    /// Runs the flush waiters once nothing more will go now.
    private func release() {
        guard !inFlight, !waiters.isEmpty else { return }
        let done = waiters
        waiters = []
        for waiter in done { waiter() }
    }

    private func drop(_ count: Int) {
        let gone = pending.prefix(count).reduce(0) { $0 + $1.text.utf8.count + 1 }
        pending.removeFirst(min(count, pending.count))
        pendingBytes -= gone
        rewrite()
    }

    /// Past 1 MB the oldest lines go, down to three quarters, and the next message says how many.
    private func trim() {
        var removed = 0
        var bytes = pendingBytes
        while bytes > Self.maxPending * 3 / 4, removed < pending.count {
            bytes -= pending[removed].text.utf8.count + 1
            removed += 1
        }
        pending.removeFirst(removed)
        pendingBytes = bytes
        dropped += removed
        rewrite()
    }

    private func persist(_ line: DiagLine) {
        if writer == nil {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(
                    atPath: file.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            }
            writer = try? FileHandle(forWritingTo: file)
            _ = try? writer?.seekToEnd()
        }
        try? writer?.write(contentsOf: Data("\(line.level.rawValue)\t\(line.text)\n".utf8))
    }

    private func rewrite() {
        try? writer?.close()
        writer = nil
        guard !pending.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let text = pending.map { "\($0.level.rawValue)\t\($0.text)\n" }.joined()
        try? Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Sends one ntfy request: the live log, Test Connection and reports share it.
enum NtfyClient {
    struct Outcome: Sendable {
        /// Nil when the server did not answer.
        var answer: NtfyAnswer?
        var status: Int?
        var retryAfter: String?
        /// Why there was no answer: the error's domain, code and words.
        var error: String?
    }

    static func send(_ request: PlexRequest, session: URLSession, completion: @escaping @Sendable (Outcome) -> Void) {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let handler: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { data, response, error in
            guard let http = response as? HTTPURLResponse else {
                completion(Outcome(error: error.map(DiagFormat.describe) ?? "no answer"))
                return
            }
            completion(Outcome(
                answer: NtfyAnswer(status: http.statusCode, body: data ?? Data()), status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            ))
        }
        if let body = request.body {
            session.uploadTask(with: urlRequest, from: body, completionHandler: handler).resume()
        } else {
            session.dataTask(with: urlRequest, completionHandler: handler).resume()
        }
    }

    static func send(_ request: PlexRequest, session: URLSession) async -> Outcome {
        await withCheckedContinuation { continuation in
            send(request, session: session) { continuation.resume(returning: $0) }
        }
    }
}
