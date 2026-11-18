import Foundation
import MarqueeCore

/// The diagnostic log on the phone (DESIGN §8.12), always kept: a file per launch, cut at 1 MB, with files
/// older than a day or past 8 MB in all removed. It sits in Application Support out of backups, writable
/// while the phone is locked so background downloads still log. A marker file says how far the launch got,
/// so the next one can tell whether it ended cleanly. Used only on the log's queue.
final class DiagJournal {
    enum Phase: String, Codable {
        case launching, foreground, background, ended
    }

    /// What the launch before this one left: how far it got, and its last lines.
    struct Previous {
        var launch: String
        var version: String
        var phase: Phase
        var playback: String?
        var updated: Date
        var tail: [String]
    }

    private struct Marker: Codable {
        var launch: String
        var version: String
        var phase: Phase
        var playback: String?
        var updated: Date
    }

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    /// The previous launch's last lines that come along when it ended unexpectedly.
    private static let tailLines = 60
    private static let tailBytes = 64 * 1024
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    private let folder: URL
    private let launch: String
    private let stamp: String
    private let policy = DiagJournalPolicy()
    private var marker: Marker
    private var handle: FileHandle?
    private var current: String?
    private var currentBytes = 0
    private var part = 0

    init(folder: URL, launch: String) {
        self.folder = folder
        self.launch = launch
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        stamp = String(format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                       parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        marker = Marker(launch: launch, version: AppBuild.version, phase: .launching, updated: Date())
    }

    /// Creates the folder, reads what the last launch left, marks this one as launching and starts its file.
    func open() -> Previous? {
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try? url.setResourceValues(values)
        let previous = readPrevious()
        writeMarker()
        startFile()
        prune()
        return previous
    }

    func append(_ text: String) {
        let data = Data((text + "\n").utf8)
        if handle == nil || policy.rotates(currentBytes: currentBytes, adding: data.count) {
            startFile()
            prune()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentBytes += data.count
        } catch {
            // A full disk: the line is lost, the next file is tried on the next line.
            self.handle = nil
        }
    }

    func mark(_ phase: Phase, playback: String?) {
        guard marker.phase != phase || marker.playback != playback else { return }
        marker.phase = phase
        marker.playback = playback
        marker.updated = Date()
        writeMarker()
        if phase != .foreground { try? handle?.synchronize() }
    }

    /// Every file, oldest first.
    func allData() -> Data {
        try? handle?.synchronize()
        var data = Data()
        for file in files() {
            if let contents = try? Data(contentsOf: folder.appending(path: file.name)) { data.append(contents) }
        }
        return data
    }

    func erase() {
        try? handle?.close()
        handle = nil
        for file in files() { try? FileManager.default.removeItem(at: folder.appending(path: file.name)) }
        part = 0
        startFile()
    }

    private func startFile() {
        try? handle?.close()
        part += 1
        let name = "\(stamp)-\(launch)-\(String(format: "%02d", part)).log"
        let url = folder.appending(path: name)
        let header = Data("# Marquee \(AppBuild.version) (\(AppBuild.build)) \(AppBuild.commit) launch=\(launch) part=\(part)\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: header, attributes: [.protectionKey: Self.protection])
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        current = name
        currentBytes = header.count
    }

    private func prune() {
        let names = policy.removals(files(), current: current, now: Date())
        for name in names { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    /// The journal files, oldest first.
    private func files() -> [DiagJournalPolicy.File] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.filter { $0.pathExtension == "log" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return DiagJournalPolicy.File(
                name: url.lastPathComponent, bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
    }

    private var markerURL: URL {
        folder.appending(path: "session.json")
    }

    private func writeMarker() {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: markerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readPrevious() -> Previous? {
        guard let data = try? Data(contentsOf: markerURL), let last = try? JSONDecoder().decode(Marker.self, from: data) else {
            return nil
        }
        let newest = files().last { $0.name.contains("-\(last.launch)-") }
        return Previous(
            launch: last.launch, version: last.version, phase: last.phase, playback: last.playback, updated: last.updated,
            tail: newest.map { tail(of: folder.appending(path: $0.name)) } ?? []
        )
    }

    private func tail(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        // A read that started mid-file starts mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.filter { !$0.hasPrefix("#") }.suffix(Self.tailLines))
    }
}
