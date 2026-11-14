import Foundation
import LumaRemoteCore
import MarqueeCore
import Network
import Synchronization

/// Where a link's messages go: the encrypted connection to the other phone, or the UI tests' stand-in.
@MainActor
protocol LinkWire: AnyObject {
    func send(_ message: LinkMessage)
    func close()
}

/// The link's Bonjour service, its TCP, and the two handshakes over it (DESIGN §8.10). The encryption is
/// LumaTV's Noise handshake and frames from LumaRemoteCore, keyed by the pair's own keys.
enum LinkTransport {
    static let serviceType = "_marquee-link._tcp"

    /// TCP with Nagle off, so a swipe goes out the moment it is sealed. Peer-to-peer Wi-Fi (AWDL, as AirDrop
    /// uses) lets two phones near each other find and reach each other with no shared network, or none at
    /// all, as long as Wi-Fi is on. Cellular is never used: it can only fail slowly.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// Browsing takes the same peer-to-peer path, or a nearby phone off any shared network is never seen.
    static func browseParameters() -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        return parameters
    }

    /// A call to a phone's Bonjour instance, which is named by its link id. A path that waits or fails ends
    /// the connection at once, so a read throws instead of hanging; the caller's deadline bounds the rest.
    /// `failure` keeps what the system said when it did.
    static func dial(_ id: LinkID, failure: DialFailure? = nil) -> TCPStream {
        let endpoint = NWEndpoint.service(name: id.description, type: serviceType, domain: "local.", interface: nil)
        let connection = NWConnection(to: endpoint, using: parameters())
        connection.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                failure?.record(error)
                connection.cancel()
            default: break
            }
        }
        return TCPStream.accept(connection)
    }

    /// kDNSServiceErr_PolicyDenied: the person has not allowed Local Network for the app.
    private static let policyDenied: Int32 = -65570

    /// Why a call to `name` did not get through, in words for the person: Local Network refused, Wi-Fi
    /// switched off (peer-to-peer needs the radio on, not a network), or neither is known.
    static func unreachableReason(_ name: String, failure: DialFailure) async -> String {
        if case .dns(let code)? = failure.error, code == policyDenied {
            return "Marquee isn’t allowed to find nearby iPhones. Allow Local Network for Marquee in Settings › Privacy & Security › Local Network."
        }
        if await !wifiAvailable() {
            return "Turn on Wi-Fi on this iPhone (you don’t need to join a network), then try again."
        }
        return "Couldn’t reach \(name). Keep both iPhones near each other with Wi-Fi switched on (it needn’t be connected to a network), or on the same Wi-Fi, with Marquee open on both and the code still showing. Make sure the other iPhone has Marquee 0.1.39 or later."
    }

    /// Whether this iPhone has a Wi-Fi interface up at all.
    private static func wifiAvailable() async -> Bool {
        let monitor = NWPathMonitor()
        let answered = AnswerOnce()
        return await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                guard answered.first() else { return }
                monitor.cancel()
                continuation.resume(returning: path.availableInterfaces.contains { $0.type == .wifi })
            }
            monitor.start(queue: .global())
        }
    }

    /// The caller's side: the preamble and the first handshake message in one write, then the answer.
    static func call(_ stream: TCPStream, preamble: LinkPreamble, psk: Data) async throws -> LinkChannel {
        var handshake = NoiseHandshake(role: .initiator, prologue: preamble.bytes, psk: psk)
        stream.send(preamble.bytes + (try handshake.writeFirst()))
        let reply = try await stream.receive(exactly: NoiseHandshake.messageLength)
        return LinkChannel(stream: stream, session: try handshake.readSecond(reply))
    }

    /// Who is calling, and whether to pair or to open a session.
    static func preamble(_ stream: TCPStream) async throws -> LinkPreamble {
        guard let preamble = LinkPreamble(bytes: try await stream.receive(exactly: LinkPreamble.length)) else {
            throw StreamError.closed
        }
        return preamble
    }

    /// The answering side. A caller without the key fails the first message's tag here, before any reply.
    static func answer(_ stream: TCPStream, preamble: LinkPreamble, psk: Data) async throws -> LinkChannel {
        var handshake = NoiseHandshake(role: .responder, prologue: preamble.bytes, psk: psk)
        try handshake.readFirst(try await stream.receive(exactly: NoiseHandshake.messageLength))
        let (reply, session) = try handshake.writeSecond()
        stream.send(reply)
        return LinkChannel(stream: stream, session: session)
    }
}

/// What the system said when a call failed.
final class DialFailure: Sendable {
    private let stored = Mutex<NWError?>(nil)

    var error: NWError? { stored.withLock { $0 } }

    func record(_ error: NWError) {
        stored.withLock { $0 = $0 ?? error }
    }
}

/// True once, for the first caller: a path monitor reports again and again, and a continuation resumes once.
private final class AnswerOnce: Sendable {
    private let done = Mutex(false)

    func first() -> Bool {
        done.withLock {
            let first = !$0
            $0 = true
            return first
        }
    }
}

/// An open link: one sealed frame per message. Sends may come from any thread; one task reads.
final class LinkChannel: Sendable {
    let stream: TCPStream
    private let sealer: Mutex<FrameSealer>
    private let opener: Mutex<FrameOpener>

    init(stream: TCPStream, session: NoiseSession) {
        self.stream = stream
        sealer = Mutex(FrameSealer(cipher: session.send))
        opener = Mutex(FrameOpener(cipher: session.receive))
    }

    /// Seals and queues one message. Sealing and queueing share the lock, so frames leave in nonce order.
    /// Status is cut to fit a frame before it gets here (`LinkStatus.limited()`).
    func send(_ message: LinkMessage) {
        guard let plaintext = try? message.encoded() else { return }
        sealer.withLock { sealer in
            if let frame = try? sealer.seal(plaintext) { stream.send(frame) }
        }
    }

    /// The other phone's next message; kinds this version does not know are skipped. Throws once the
    /// connection ends or a frame fails to open.
    func receive() async throws -> LinkMessage {
        while true {
            if let plaintext = try opener.withLock({ try $0.next() }) {
                if let message = LinkMessage.decode(plaintext) { return message }
                continue
            }
            let bytes = try await stream.receive(maximum: 16 * 1024)
            opener.withLock { $0.append(bytes) }
        }
    }

    func close() {
        stream.close()
    }
}

extension LinkChannel: LinkWire {}

extension LinkInput {
    init(_ input: GlassesInput) {
        switch input {
        case .move(let move): self = .move(move)
        case .select: self = .select
        case .back: self = .back
        case .holdBegan: self = .holdBegan
        case .holdEnded: self = .holdEnded
        case .slide(let dx, let width): self = .slide(dx: dx, width: width)
        case .nudge(let seconds): self = .nudge(seconds: seconds)
        case .panBegan: self = .panBegan
        case .pan(let dx, let dy, _): self = .pan(dx: dx, dy: dy)
        case .panEnded(let vx, let vy, _): self = .panEnded(vx: vx, vy: vy)
        }
    }
}

extension GlassesInput {
    /// The other phone's press as this phone's remote would make it, `at` when the touch happened by this
    /// phone's clock; nil for a slide across no width.
    init?(_ input: LinkInput, at time: TimeInterval?) {
        switch input {
        case .move(let move): self = .move(move)
        case .select: self = .select
        case .back: self = .back
        case .holdBegan: self = .holdBegan
        case .holdEnded: self = .holdEnded
        case .slide(let dx, let width):
            guard width > 0 else { return nil }
            self = .slide(dx: dx, width: width)
        case .nudge(let seconds): self = .nudge(seconds)
        case .panBegan: self = .panBegan
        case .pan(let dx, let dy): self = .pan(dx: dx, dy: dy, at: time)
        case .panEnded(let vx, let vy): self = .panEnded(vx: vx, vy: vy, at: time)
        }
    }

    /// When the touch behind this input happened, by the phone's clock, for the pans that carry it.
    var touchTime: TimeInterval? {
        switch self {
        case .pan(_, _, let time), .panEnded(_, _, let time): time
        default: nil
        }
    }
}
