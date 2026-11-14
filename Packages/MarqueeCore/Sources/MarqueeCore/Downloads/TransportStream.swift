import Foundation

/// Joins the MPEG-TS segments of two transcode sessions without repeating frames. A session started
/// at an offset begins at the source's keyframe before it (offset 3200 began at 3198.03 on PMS
/// 1.43.5), so its first segment repeats some of what was saved. A remuxer meeting time that runs
/// backwards may stop, so the repeat is dropped: video resumes at the first keyframe after the saved
/// video, audio just after the saved audio. Plex's encoder puts a keyframe every second, so at most
/// about a second of picture is skipped at the join.
public enum TransportStream {
    /// The latest presentation time saved of each kind, in 90 kHz ticks.
    public struct Timestamps: Hashable, Sendable, Codable {
        public var video: Int64?
        public var audio: Int64?

        public init(video: Int64? = nil, audio: Int64? = nil) {
            self.video = video
            self.audio = audio
        }
    }

    static let packetSize = 188

    /// `earlier` moved on by the frames in `data`.
    public static func latest(in data: Data, after earlier: Timestamps) -> Timestamps {
        var latest = earlier
        forEachPacket(in: data) { packet in
            guard let pes = packet.pes, let pts = pes.pts else { return }
            switch pes.kind {
            case .video: latest.video = max(latest.video ?? pts, pts)
            case .audio: latest.audio = max(latest.audio ?? pts, pts)
            case .other: break
            }
        }
        return latest
    }

    /// `data` without the frames at or before `saved`. `resumed` is true once every kind saved before
    /// has come back; until then the next segment is trimmed too. Data that is not whole packets, or
    /// whose times are not on the saved ones' timeline (more than a minute before them), stays as it
    /// is.
    public static func trimmed(_ data: Data, after saved: Timestamps) -> (data: Data, resumed: Bool) {
        guard data.count % packetSize == 0 else { return (data, true) }
        var output = Data(capacity: data.count)
        var keeps: [Int: Bool] = [:]
        var videoBack = saved.video == nil
        var audioBack = saved.audio == nil
        var firstVideo: Int64?
        var whole = true
        forEachPacket(in: data) { packet in
            guard packet.isSynced else {
                whole = false
                return
            }
            if let pes = packet.pes {
                switch pes.kind {
                case .video:
                    if firstVideo == nil { firstVideo = pes.pts }
                    if !videoBack, let pts = pes.pts, let last = saved.video, pts > last, packet.isRandomAccess { videoBack = true }
                    keeps[packet.pid] = videoBack
                case .audio:
                    if !audioBack, let pts = pes.pts, let last = saved.audio, pts > last { audioBack = true }
                    keeps[packet.pid] = audioBack
                case .other:
                    keeps[packet.pid] = true
                }
            }
            if keeps[packet.pid] ?? true { output.append(packet.bytes) }
        }
        let minute: Int64 = 60 * 90_000
        if !whole { return (data, true) }
        if let firstVideo, let last = saved.video, firstVideo < last - minute { return (data, true) }
        return (output, videoBack && audioBack)
    }

    struct Packet {
        let bytes: Data
        let isSynced: Bool
        let pid: Int
        let isRandomAccess: Bool
        /// The header of the PES this packet starts, if it starts one.
        let pes: PES?
    }

    struct PES {
        enum Kind { case video, audio, other }
        let kind: Kind
        let pts: Int64?
    }

    private static func forEachPacket(in data: Data, _ body: (Packet) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start + packetSize <= bytes.count {
                body(packet(bytes, at: start, data: data))
                start += packetSize
            }
        }
    }

    private static func packet(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, data: Data) -> Packet {
        let slice = data.subdata(in: data.startIndex + start..<data.startIndex + start + packetSize)
        guard bytes[start] == 0x47 else { return Packet(bytes: slice, isSynced: false, pid: -1, isRandomAccess: false, pes: nil) }
        let startsUnit = bytes[start + 1] & 0x40 != 0
        let pid = Int(bytes[start + 1] & 0x1F) << 8 | Int(bytes[start + 2])
        let control = (bytes[start + 3] >> 4) & 0x3
        var payload = start + 4
        var randomAccess = false
        if control & 0x2 != 0 {
            let length = Int(bytes[start + 4])
            randomAccess = length > 0 && bytes[start + 5] & 0x40 != 0
            payload = start + 5 + length
        }
        let end = start + packetSize
        var pes: PES?
        if startsUnit, control & 0x1 != 0, payload + 9 <= end,
           bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1 {
            let id = bytes[payload + 3]
            let kind: PES.Kind = switch id {
            case 0xE0...0xEF: .video
            case 0xC0...0xDF, 0xBD: .audio
            default: .other
            }
            var pts: Int64?
            if bytes[payload + 7] & 0x80 != 0, payload + 14 <= end {
                let p = payload + 9
                pts = Int64(bytes[p] & 0x0E) << 29 | Int64(bytes[p + 1]) << 22 | Int64(bytes[p + 2] & 0xFE) << 14
                    | Int64(bytes[p + 3]) << 7 | Int64(bytes[p + 4]) >> 1
            }
            pes = PES(kind: kind, pts: pts)
        }
        return Packet(bytes: slice, isSynced: true, pid: pid, isRandomAccess: randomAccess, pes: pes)
    }
}
