import Foundation

/// Why a Plex request failed. Never carries a token or a URL, so it is safe to log.
public enum PlexError: Error, Sendable, Equatable {
    /// The token was refused (HTTP 401). The app should ask to sign in again.
    case unauthorized
    /// No HTTP answer at all: offline, wrong address, timed out.
    case unreachable(NetworkFailure)
    /// The host answered with an error status. `message` is Plex's own wording when it sent one.
    case server(status: Int, message: String?)
    /// The answer did not have the expected shape.
    case decoding(String)
    /// The sign-in code expired before the account was linked.
    case pinExpired
    /// plex.tv refused the profile PIN.
    case profilePINRejected
    /// The server lists no address the app is allowed to use.
    case noConnections
}

/// A request that got no HTTP answer, in the terms the app acts on.
public enum NetworkFailure: Error, Sendable, Equatable {
    case timedOut
    /// An open connection dropped, typically a kept-alive socket the server had already closed.
    case connectionLost
    case cannotConnect
    case hostNotFound
    case offline
    case secureConnectionFailed
    case other

    /// Worth one immediate retry: the next attempt opens a fresh connection or lookup.
    /// Timeouts are excluded because a retry would double an already long wait.
    public var isTransient: Bool {
        switch self {
        case .connectionLost, .cannotConnect, .hostNotFound: true
        case .timedOut, .offline, .secureConnectionFailed, .other: false
        }
    }
}

extension PlexError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unauthorized: "Plex refused the sign-in token"
        case .unreachable(let failure): "Plex could not be reached (\(failure))"
        case .server(let status, let message): "Plex answered \(status)" + (message.map { ": \($0)" } ?? "")
        case .decoding(let detail): "Unexpected answer from Plex: \(detail)"
        case .pinExpired: "The sign-in code expired"
        case .profilePINRejected: "Wrong profile PIN"
        case .noConnections: "The server lists no usable address"
        }
    }
}
