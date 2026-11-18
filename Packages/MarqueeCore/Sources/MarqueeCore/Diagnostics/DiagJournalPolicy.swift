import Foundation

/// The bounds of the on-phone journal: files of at most 1 MB, a new one each launch, and together about
/// the last 24 hours or 8 MB, whichever is less. A whole journal still fits one ntfy attachment (15 MB).
public struct DiagJournalPolicy: Sendable, Equatable {
    public var fileBytes: Int
    public var totalBytes: Int
    public var maxAge: TimeInterval

    public init(fileBytes: Int = 1_000_000, totalBytes: Int = 8_000_000, maxAge: TimeInterval = 24 * 3600) {
        self.fileBytes = fileBytes
        self.totalBytes = totalBytes
        self.maxAge = maxAge
    }

    public struct File: Sendable, Equatable {
        public var name: String
        public var bytes: Int
        /// The last write.
        public var modified: Date

        public init(name: String, bytes: Int, modified: Date) {
            self.name = name
            self.bytes = bytes
            self.modified = modified
        }
    }

    /// Whether `adding` more bytes starts a new file.
    public func rotates(currentBytes: Int, adding: Int) -> Bool {
        currentBytes > 0 && currentBytes + adding > fileBytes
    }

    /// The files to delete: every one last written more than `maxAge` ago, then the oldest until the rest
    /// fit `totalBytes`. The file being written is never among them.
    public func removals(_ files: [File], current: String?, now: Date) -> [String] {
        let ordered = files.sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
        var removed: [String] = []
        var total = ordered.reduce(0) { $0 + $1.bytes }
        for file in ordered where file.name != current {
            let expired = now.timeIntervalSince(file.modified) > maxAge
            guard expired || total > totalBytes else { continue }
            removed.append(file.name)
            total -= file.bytes
        }
        return removed
    }
}
