/// What the server's answer to a delete means for the title.
public enum DeleteOutcome: Equatable, Sendable {
    /// The title is gone: deleted now (200, 204), or gone already (404).
    case deleted
    /// Deleting is turned off on the server, or this profile may not delete (401, 403). Asking again
    /// cannot help, so it is never retried.
    case notAllowed
    /// A server fault or no answer; Retry may work.
    case failed

    /// The outcome of a delete that threw `error`.
    public init(_ error: any Error) {
        switch error as? PlexError {
        case .unauthorized, .server(401, _), .server(403, _): self = .notAllowed
        case .server(404, _): self = .deleted
        default: self = .failed
        }
    }
}

/// Titles deleted during this session. Plex lists a deleted title until its trash is emptied, so
/// screens drop these from whatever the server answers rather than trusting a refetch.
public struct DeletedTitles: Equatable, Sendable {
    private var keys: Set<String> = []

    public init() {}

    public mutating func insert(_ ratingKey: String) {
        keys.insert(ratingKey)
    }

    /// Whether `item` was deleted, or belongs to a deleted season or show.
    public func contains(_ item: PlexMetadata) -> Bool {
        keys.contains(item.ratingKey)
            || item.parentRatingKey.map(keys.contains) == true
            || item.grandparentRatingKey.map(keys.contains) == true
    }

    /// `items` in their order, without the deleted ones.
    public func removing(from items: [PlexMetadata]) -> [PlexMetadata] {
        keys.isEmpty ? items : items.filter { !contains($0) }
    }
}
