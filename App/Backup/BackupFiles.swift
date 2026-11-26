import Foundation
import MarqueeCore

/// The files a backup touches: one the person picked in Files, and the one file automatic backups are written to.
/// Everything here blocks on file coordination (a network share or iCloud may be slow), so it runs through
/// `blocking`, never on the main actor.
enum BackupFiles {
    /// A backup is a few kilobytes; a file far larger than this is not one.
    static let sizeLimit = 8_000_000

    /// What stops a file from being read or written, beyond `BackupError`.
    enum Failure: Error, Equatable {
        /// iCloud has not put the file on this iPhone yet.
        case notDownloaded
        /// The file holds another Plex account's backup, which is never replaced.
        case otherAccount
        /// The file holds a backup newer than any this iPhone wrote or restored.
        case newer(Date)
        /// The system no longer lets Marquee reach the file.
        case fileUnavailable
    }

    /// Runs file work on a background queue, so a slow share cannot hold a thread of the cooperative pool.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// A bookmark for a file from the picker, which keeps it reachable after a relaunch.
    static func bookmark(for file: URL) throws -> Data {
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        return try file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The file's name and where it lives, for the Backup page ("iCloud Drive › Marquee").
    static func place(of file: URL) -> String {
        let parts = file.deletingLastPathComponent().pathComponents
        if let cloud = parts.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + parts[(cloud + 1)...]).joined(separator: " › ")
        }
        return parts.last ?? ""
    }

    /// A backup the person picked, or one iOS copied into the app's inbox when it was opened from Files; that
    /// copy goes once it is read.
    static func read(picked url: URL) throws -> Data {
        let opened = url.startAccessingSecurityScopedResource()
        defer {
            if opened { url.stopAccessingSecurityScopedResource() }
            removeInboxCopy(url)
        }
        guard let data = try coordinatedRead(url) else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    /// The chosen file's contents, or nil when it is empty or gone.
    static func current(at bookmark: Data) throws -> Data? {
        try withFile(bookmark) { try coordinatedRead($0) }.value
    }

    /// Rewrites the chosen file in place. Another account's backup is never replaced, and neither is one newer
    /// than `knownNewest` (the newest this iPhone wrote or restored) unless `replacingNewer` says the person
    /// chose that. Returns a fresh bookmark when the system marked the old one stale.
    static func write(
        _ data: Data, at bookmark: Data, account: String, knownNewest: Int, replacingNewer: Bool
    ) throws -> Data? {
        try withFile(bookmark) { file in
            if let existing = try coordinatedRead(file), let header = try? Backup.inspect(existing) {
                guard Backup.belongs(header, to: account) else { throw Failure.otherAccount }
                guard replacingNewer || header.createdAt <= knownNewest else { throw Failure.newer(header.createdDate) }
            }
            try coordinatedWrite(data, to: file)
        }.refreshed
    }

    private static func withFile<T>(_ bookmark: Data, _ body: (URL) throws -> T) throws -> (value: T, refreshed: Data?) {
        var stale = false
        let file: URL
        do {
            file = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw Failure.fileUnavailable
        }
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        let value = try body(file)
        var refreshed: Data?
        if stale { refreshed = try? file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        return (value, refreshed)
    }

    private static func coordinatedRead(_ url: URL) throws -> Data? {
        try waitForDownload(url)
        var outcome: Result<Data?, any Error> = .success(nil)
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= sizeLimit else { throw BackupError.notABackup }
                outcome = .success(try Data(contentsOf: readable))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                outcome = .success(nil)
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError {
            let code = (coordinationError as? CocoaError)?.code
            if code == .fileReadNoSuchFile || code == .fileNoSuchFile { return nil }
            throw coordinationError
        }
        return try outcome.get()
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var failure: (any Error)?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writable in
            do { try data.write(to: writable, options: .atomic) } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }

    /// Waits up to ten seconds for iCloud to put the file on this iPhone, so a coordinated read does not sit
    /// waiting on a connection that is not there.
    private static func waitForDownload(_ url: URL) throws {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true else { return }
        func isHere() -> Bool {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            return status == .current || status == .downloaded
        }
        if isHere() { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            if isHere() { return }
        }
        throw Failure.notDownloaded
    }

    /// A file opened from Files arrives as a copy in the app's own Inbox; once it is read, or turned away, the
    /// copy goes, so no backup lingers in the app's storage. A file anywhere else is never touched.
    static func removeInboxCopy(_ url: URL) {
        let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath().path
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              url.resolvingSymlinksInPath().path.hasPrefix(home)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
