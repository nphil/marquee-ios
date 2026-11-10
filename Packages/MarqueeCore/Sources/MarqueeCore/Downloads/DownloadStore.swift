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
        folder(for: record).appending(path: record.partialID.map { "download-\($0.uuidString).part" } ?? "download.part")
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

    /// The title's picture for lists: an episode's still or a movie's backdrop, which the lists draw
    /// without the server.
    public func stillFile(for record: DownloadRecord) -> URL {
        folder(for: record).appending(path: "still.jpg")
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
    /// version in place of the original's. The separate subtitle files saved with a conversion are
    /// the original's, so their streams join the converted file's.
    public func offlineItem(for record: DownloadRecord) throws -> PlexMetadata {
        var item = try PlexMetadata.fromSnapshot(Data(contentsOf: metadataFile(for: record)))
        let original = item.media.indices.contains(record.mediaIndex) ? item.media[record.mediaIndex] : nil
        guard record.quality != .original else {
            item.media = original.map { [$0] } ?? []
            return item
        }
        item.media = try PlexMetadata.fromSnapshot(Data(contentsOf: decisionFile(for: record))).media
        let saved = Set(record.subtitles.map(\.streamID))
        let sidecars = (original?.parts ?? []).flatMap(\.streams).filter { saved.contains($0.id) }
        if !item.media.isEmpty, !item.media[0].parts.isEmpty {
            let present = Set(item.media[0].parts[0].streams.map(\.id))
            item.media[0].parts[0].streams += sidecars.filter { !present.contains($0.id) }
        }
        return item
    }

    /// The picture's size of a download saved by an older version, read from its saved description;
    /// nil when that is missing or does not say.
    public func savedFrame(for record: DownloadRecord) -> DownloadRecord.Frame? {
        guard let data = try? Data(contentsOf: metadataFile(for: record)),
              let item = try? PlexMetadata.fromSnapshot(data),
              item.media.indices.contains(record.mediaIndex) else { return nil }
        return DownloadRecord.Frame(media: item.media[record.mediaIndex], quality: record.quality)
    }

    /// The artwork path to keep as the title's still, from its saved description.
    public func savedStillPath(for record: DownloadRecord) -> String? {
        guard let data = try? Data(contentsOf: metadataFile(for: record)), let item = try? PlexMetadata.fromSnapshot(data) else { return nil }
        return DownloadRecord.stillPath(of: item)
    }

    /// `file`'s path below `base`, joined by "/", built from path components so a trailing slash on
    /// either URL changes nothing. Nil when `file` is not inside `base`. The background transfer keeps
    /// this instead of an absolute path because the app container's path can change between launches.
    public static func relativePart(of file: URL, under base: URL) -> String? {
        let base = base.standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// The inverse of `relativePart(of:under:)`.
    public static func file(forPart part: String, under base: URL) -> URL {
        base.appending(path: part)
    }

    private var indexFile: URL { root.appending(path: "index.json") }

    /// Every record, in the order added. An unreadable index reads as none.
    public func loadIndex() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: indexFile) else { return [] }
        return (try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? []
    }

    public func saveIndex(_ records: [DownloadRecord]) throws {
        try prepareRoot()
        try JSONEncoder().encode(records).write(to: indexFile, options: .atomic)
    }

    /// Makes the downloads folder and keeps it out of iCloud and device backups: the videos come from
    /// the server and can be fetched again. The folder is under Application Support, so iOS counts it
    /// as the app's Documents & Data in iPhone Storage. Backup exclusion is a property of the folder,
    /// so it is set again whenever the folder is made anew.
    public func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true else { return }
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
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
