import Foundation

/// The part file of a streamed conversion: the server's MPEG-TS segments appended in order, which
/// plays through the remux like any `.ts`. Segments iOS fetched while the app was suspended wait
/// beside it as pieces, named for their place and end time, until they are appended.
public enum StreamedFile {
    /// A segment outside the session's transcode comes back as a few packets of nothing rather than an
    /// error (188 bytes on PMS 1.43.5): the session has to start again there.
    public static func isPlaceholder(_ length: Int) -> Bool {
        length <= 4 * 188
    }

    /// Makes the file agree with what the record saved: a write the app's end cut short is dropped,
    /// and a file shorter than the record starts the download over.
    public static func prepare(_ file: URL, stream: inout DownloadRecord.Stream) throws {
        let path = file.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let length = Int64((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        if length < stream.bytes {
            stream = DownloadRecord.Stream(session: stream.session)
        }
        guard length != stream.bytes else { return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(stream.bytes))
    }

    /// Appends one segment ending `end` seconds into the title, flushed to disk. After a new session
    /// began, what repeats saved frames is left out first.
    public static func append(_ data: Data, ending end: Double, to file: URL, stream: inout DownloadRecord.Stream) throws {
        var kept = data
        if stream.joining {
            let trimmed = TransportStream.trimmed(data, after: stream.timestamps)
            kept = trimmed.data
            stream.joining = !trimmed.resumed
        }
        if !kept.isEmpty {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(stream.bytes))
            try handle.write(contentsOf: kept)
            try handle.synchronize()
        }
        stream.bytes += Int64(kept.count)
        stream.timestamps = TransportStream.latest(in: kept, after: stream.timestamps)
        stream.pieces += 1
        stream.saved = end
        stream.restarts = 0
    }

    /// `download-<id>.part.12-3216000.ts`: the 12th segment, ending 3216 s into the title.
    public static func pieceName(of file: URL, number: Int, end: Double) -> String {
        "\(file.lastPathComponent).\(number)-\(Int((end * 1000).rounded())).ts"
    }

    /// A waiting piece.
    public struct Piece: Hashable, Sendable {
        public var url: URL
        public var number: Int
        /// Seconds into the title.
        public var end: Double
    }

    /// The waiting pieces of `file`, in order.
    public static func pieces(of file: URL) -> [Piece] {
        let folder = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.compactMap { name -> Piece? in
            guard name.hasPrefix(prefix), name.hasSuffix(".ts") else { return nil }
            let fields = name.dropFirst(prefix.count).dropLast(3).split(separator: "-")
            guard fields.count == 2, let number = Int(fields[0]), let millis = Int(fields[1]) else { return nil }
            return Piece(url: folder.appending(path: name), number: number, end: Double(millis) / 1000)
        }
        .sorted { $0.number < $1.number }
    }

    /// Appends the waiting pieces that continue the file, in order, and returns them for deleting once
    /// the record that counts them is saved. Pieces already counted are returned too; pieces after a
    /// gap wait.
    public static func absorb(into file: URL, stream: inout DownloadRecord.Stream) throws -> [URL] {
        var done: [URL] = []
        for piece in pieces(of: file) {
            if piece.number < stream.pieces {
                done.append(piece.url)
                continue
            }
            guard piece.number == stream.pieces else { break }
            try append(Data(contentsOf: piece.url), ending: piece.end, to: file, stream: &stream)
            done.append(piece.url)
        }
        return done
    }
}
