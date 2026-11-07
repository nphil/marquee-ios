import Foundation

/// One round of `/identity` probes and the address it picked, kept for diagnostics: a LAN probe that
/// fails at once as offline while the remote one answers is what iOS's Local Network block looks like.
public struct ProbeRound: Sendable, Hashable {
    public struct Probe: Sendable, Hashable {
        public enum Outcome: Sendable, Hashable {
            /// Answered as this server.
            case answered
            /// Answered as a different machine.
            case otherServer
            /// Answered with an HTTP error status.
            case status(Int)
            case failed(NetworkFailure)
            /// Still waiting for an answer when another address was picked.
            case pending
        }

        public let connection: PlexConnection
        public let outcome: Outcome
        /// From the start of the round to the answer, or to the pick for `.pending`.
        public let seconds: TimeInterval

        public init(connection: PlexConnection, outcome: Outcome, seconds: TimeInterval) {
            self.connection = connection
            self.outcome = outcome
            self.seconds = seconds
        }
    }

    public let started: Date
    public let probes: [Probe]
    /// Nil when no address answered as this server.
    public let picked: PlexConnection?

    public init(started: Date, probes: [Probe], picked: PlexConnection?) {
        self.started = started
        self.probes = probes
        self.picked = picked
    }
}

extension ProbeRound {
    /// "Local 192.168.1.69: offline after 12 ms", one line per address, for stats and diagnostics.
    public var lines: [String] {
        probes.map { probe in
            let ms = Int((probe.seconds * 1000).rounded())
            let result = switch probe.outcome {
            case .answered: "answered in \(ms) ms"
            case .otherServer: "another server answered in \(ms) ms"
            case .status(let code): "HTTP \(code) after \(ms) ms"
            case .failed(let failure): "\(failure.words) after \(ms) ms"
            case .pending: "no answer after \(ms) ms"
            }
            let marker = probe.connection == picked ? " (used)" : ""
            return "\(probe.connection.kindWord) \(probe.connection.displayAddress): \(result)\(marker)"
        }
    }
}

extension PlexConnection {
    /// "Local", "Remote" or "Relay".
    public var kindWord: String { isRelay ? "Relay" : isLocal ? "Local" : "Remote" }
}

extension NetworkFailure {
    var words: String {
        switch self {
        case .timedOut: "timed out"
        case .connectionLost: "connection lost"
        case .cannotConnect: "refused"
        case .hostNotFound: "name not found"
        // What iOS reports for a LAN address while Local Network access is off or still being asked.
        case .offline: "offline"
        case .secureConnectionFailed: "TLS failed"
        case .other: "failed"
        }
    }
}
