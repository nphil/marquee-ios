import Foundation

/// One channel's stream and its timeshift buffer, shared by the pipelines that play it: the one that tuned it and those
/// a seek starts on the same bytes. The request goes out with the first pipeline; the tuner is held, paused or not,
/// until the last one stops, and then the buffer is deleted.
public final class LiveFeed: @unchecked Sendable {
    public let buffer: TimeshiftBuffer
    private let url: URL?
    private let lock = NSLock()
    // Guarded by `lock`.
    private var connection: TunerConnection?
    private var listener: (@Sendable (TunerConnection.Event) -> Void)?
    private var started = false
    private var users = 0
    private var answered: Bool
    private var _ending: LivePipeline.Event?

    /// The tuner's stream at `url` (`…/auto/v<channel>`).
    public init(url: URL, buffer: TimeshiftBuffer) {
        self.url = url
        self.buffer = buffer
        answered = false
    }

    /// Bytes the caller writes into `buffer`: a recording, in tests and screenshots.
    public init(buffer: TimeshiftBuffer) {
        url = nil
        self.buffer = buffer
        answered = true
    }

    /// How the stream stopped once the tuner's connection ended: `.ended` or `.lost`.
    var ending: LivePipeline.Event? { lock.withLock { _ending } }

    /// Joins a pipeline. The first one sends the request and hears the connection's events; the result says whether
    /// the tuner has already answered, so a later one can take over at once.
    func attach(_ onEvent: @escaping @Sendable (TunerConnection.Event) -> Void) -> Bool {
        let (connection, answered) = lock.withLock { () -> (TunerConnection?, Bool) in
            users += 1
            guard let url, !started else { return (nil, answered) }
            started = true
            listener = onEvent
            let connection = TunerConnection(url: url, buffer: buffer) { [weak self] event in self?.handle(event) }
            self.connection = connection
            return (connection, false)
        }
        connection?.start()
        return answered
    }

    /// Leaves a pipeline. The last one frees the tuner and deletes the buffer, off the calling thread: a long session
    /// leaves a hundred segment files.
    func detach() {
        let (last, connection) = lock.withLock { () -> (Bool, TunerConnection?) in
            users -= 1
            guard users == 0 else { return (false, nil) }
            defer {
                self.connection = nil
                listener = nil
            }
            return (true, self.connection)
        }
        guard last else { return }
        connection?.cancel()
        let buffer = buffer
        DispatchQueue.global(qos: .utility).async { buffer.discard() }
    }

    private func handle(_ event: TunerConnection.Event) {
        let listener = lock.withLock {
            switch event {
            case .response(let status, _): if status == 200 { answered = true }
            case .ended(let error): _ending = error.map { .lost($0) } ?? .ended
            case .firstByte, .refused: break
            }
            return self.listener
        }
        listener?(event)
    }
}
