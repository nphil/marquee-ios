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

    /// TCP with Nagle off, so a swipe goes out the moment it is sealed, on the local network only: a
    /// cellular path can only fail slowly.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// A call to a phone's Bonjour instance, which is named by its link id. A path that waits or fails ends
    /// the connection at once, so a read throws instead of hanging; the caller's deadline bounds the rest.
    static func dial(_ id: LinkID) -> TCPStream {
        let endpoint = NWEndpoint.service(name: id.description, type: serviceType, domain: "local.", interface: nil)
        let connection = NWConnection(to: endpoint, using: parameters())
        connection.stateUpdateHandler = { state in
            switch state {
            case .waiting, .failed: connection.cancel()
            default: break
            }
        }
        return TCPStream.accept(connection)
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
        }
    }
}

extension GlassesInput {
    /// The other phone's press as this phone's remote would make it; nil for a slide across no width.
    init?(_ input: LinkInput) {
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
        }
    }
}
