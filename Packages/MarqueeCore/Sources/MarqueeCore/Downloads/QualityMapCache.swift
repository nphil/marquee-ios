import Foundation

/// The session's answers from HomeLabber's quality map, shared by the download menu and the player: one request
/// per title however many ask, then none. A measured title, or one HomeLabber calls too small to convert, is kept
/// for the session; one it has not measured yet is asked again after ten minutes, as it may be scored by then.
/// After a failed request (HomeLabber off or unreachable, a refused token) it stays quiet for a minute and every
/// title is unscored meanwhile, so a stream that starts is not held up by it again.
///
/// A different address or token, or no client at all (the plugin is off), starts it over.
public actor QualityMapCache {
    /// How long a title HomeLabber has not measured is believed.
    static let unscoredFor: TimeInterval = 600
    /// How long every title is unscored after a failed request.
    static let quietFor: TimeInterval = 60

    private struct Title: Hashable {
        var server: String
        var ratingKey: String
    }

    private let now: @Sendable () -> Date
    private var config: HomeLabberConfig?
    private var kept: [Title: (answer: QualityMapAnswer, at: Date)] = [:]
    private var lookups: [Title: Task<QualityMapAnswer?, Never>] = [:]
    private var quietUntil = Date.distantPast

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// HomeLabber's word on the title, or `.unscored` when `client` is nil or HomeLabber did not answer.
    public func answer(_ client: HomeLabberClient?, server: String, ratingKey: String) async -> QualityMapAnswer {
        if client?.config != config {
            config = client?.config
            kept = [:]
            lookups = [:]
            quietUntil = .distantPast
        }
        guard let client else { return .unscored }
        let title = Title(server: server, ratingKey: ratingKey)
        if let known = kept[title] {
            if case .unscored = known.answer, now().timeIntervalSince(known.at) >= Self.unscoredFor {
                kept[title] = nil
            } else {
                return known.answer
            }
        }
        if let running = lookups[title] { return await running.value ?? .unscored }
        guard now() >= quietUntil else { return .unscored }

        let lookup = Task { try? await client.answer(server: server, ratingKey: ratingKey) }
        lookups[title] = lookup
        let found = await lookup.value
        // The lookup was for a client that has been replaced since.
        guard config == client.config else { return found ?? .unscored }
        lookups[title] = nil
        if let found { kept[title] = (found, now()) } else { quietUntil = now().addingTimeInterval(Self.quietFor) }
        return found ?? .unscored
    }
}
