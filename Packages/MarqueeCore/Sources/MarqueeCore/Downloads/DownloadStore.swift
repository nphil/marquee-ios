import Foundation

/// Where downloads live on disk: an index of every record, and one folder per title under its server
/// and profile, holding the video, its separate subtitles, poster and the server's description.
public struct DownloadStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func folder(for record: DownloadRecord) -> URL {
        root.appending(path: Self.safe(record.scope.server), directoryHint: .isDirectory)
            .appending(path: record.scope.profile.isEmpty ? "account" : Self.safe(record.scope.profile), directoryHint: .isDirectory)
            .appending(path: Self.safe(record.ratingKey), directoryHint: .isDirectory)
    }

    /// The video while it arrives; renamed to `mediaFile` once complete.
    public func partialFile(for record: DownloadRecord) -> URL {
        folder(for: record).appending(path: "download.part")
    }

    public func mediaFile(for record: DownloadRecord) -> URL? {
        record.fileName.map { folder(for: record).appending(path: $0) }
    }

    public func subtitleFile(for record: DownloadRecord, _ subtitle: DownloadRecord.Subtitle) -> URL {
        folder(for: record).appending(path: subtitle.fileName)
    }

    public func posterFile(for record: DownloadRecord) -> URL {
        folder(for: record).appending(path: "poster.jpg")
    }

    /// The server's answer for the title, with markers and chapters.
    public func metadataFile(for record: DownloadRecord) -> URL {
        folder(for: record).appending(path: "metadata.json")
    }

    /// For a conversion, the server's description of the file it made.
    public func decisionFile(for record: DownloadRecord) -> URL {
        folder(for: record).appending(path: "decision.json")
    }

    /// The title as the player needs it offline: the server's answer, with the converted file's
    /// version in place of the original's.
    public func offlineItem(for record: DownloadRecord) throws -> PlexMetadata {
        var item = try PlexMetadata.fromSnapshot(Data(contentsOf: metadataFile(for: record)))
        if record.quality == .original {
            item.media = item.media.indices.contains(record.mediaIndex) ? [item.media[record.mediaIndex]] : []
        } else {
            item.media = try PlexMetadata.fromSnapshot(Data(contentsOf: decisionFile(for: record))).media
        }
        return item
    }

    private var indexFile: URL { root.appending(path: "index.json") }

    /// Every record, in the order added. An unreadable index reads as none.
    public func loadIndex() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: indexFile) else { return [] }
        return (try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? []
    }

    public func saveIndex(_ records: [DownloadRecord]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: indexFile, options: .atomic)
    }

    public func makeFolder(for record: DownloadRecord) throws {
        try FileManager.default.createDirectory(at: folder(for: record), withIntermediateDirectories: true)
    }

    public func remove(_ record: DownloadRecord) throws {
        let folder = folder(for: record)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func eraseAll() throws {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// What every download takes on disk, the partial ones included.
    public func bytesOnDisk() -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// A name that stays one folder, whatever the server sent.
    static func safe(_ part: String) -> String {
        let kept = part.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        return kept.isEmpty ? "_" : String(kept)
    }
}
