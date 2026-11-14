import Foundation

/// How Plex's transcoder turns `maxVideoBitrate` into a picture size and a video bitrate. Measured on
/// PMS 1.43.5 with H.264 through VAAPI (2026-11): the size comes from the cap and the frame asked for
/// is only a ceiling, and the encoder's rate is below the cap (a cap of 4000 encodes at 3419 kbit/s,
/// 1280x720). The same caps gave the same sizes to Plex Web and Plex for iOS.
public enum TranscodeLadder {
    /// The least video bitrate Plex makes at each size: below it, the same cap gives a smaller picture.
    /// The 4K floor is HEVC's, the only codec Plex converts to 2160 with; a 20 Mbit/s cap made 8727.
    public static func floor(height: Int) -> Int {
        switch height {
        case 2160...: 8750
        case 1080...: 6520
        case 720...: 2960
        default: 1050
        }
    }

    /// The cap to ask first: the measured rates inverted. A 1080 cap encodes at about 0.93 of it; 720 at
    /// 0.92 less 257; below that, 0.52 plus 268. HEVC at 2160 made 8727 for 20000 and 20121 for 40000.
    static func firstCap(videoKbps: Int, height: Int) -> Int {
        let kbps = Double(videoKbps)
        let cap = switch height {
        case 2160...: kbps / 0.47
        case 1080...: kbps / 0.93
        case 720...: (kbps + 257) / 0.92
        default: max(kbps - 268, 200) / 0.52
        }
        return roundUp(Int(cap.rounded(.up)))
    }

    /// What the server's decision says it will make for a cap.
    public struct Answer: Sendable, Hashable {
        public var videoKbps: Int
        /// The size class (480, 720, 1080, 2160).
        public var height: Int

        public init(videoKbps: Int, height: Int) {
            self.videoKbps = videoKbps
            self.height = height
        }
    }

    /// Close enough: 3 % of the target, at least 50 kbit/s.
    static func isClose(_ answer: Answer, to target: DownloadTarget) -> Bool {
        answer.height == target.height && abs(answer.videoKbps - target.videoKbps) <= max(target.videoKbps * 3 / 100, 50)
    }

    /// Finds the cap whose decision makes about the target's bitrate at its size, asking at most
    /// `attempts` decisions: a smaller picture than wanted raises the cap by a quarter, a larger one
    /// lowers it, and at the right size the next cap follows the line through the last two answers.
    /// Returns the cap with the closest answer at the right size, else the last one asked.
    public static func search(
        for target: DownloadTarget,
        attempts: Int = 4,
        decide: (Int) async throws -> Answer
    ) async throws -> (cap: Int, answer: Answer) {
        var cap = target.maxVideoBitrateKbps
        var tried: [(cap: Int, answer: Answer)] = []
        for _ in 0..<attempts {
            let answer = try await decide(cap)
            tried.append((cap, answer))
            if isClose(answer, to: target) { break }
            let next: Int
            if answer.height < target.height {
                next = cap + cap / 4
            } else if answer.height > target.height {
                next = cap - cap / 5
            } else if let previous = tried.dropLast().last(where: { $0.answer.height == target.height && $0.answer.videoKbps != answer.videoKbps }) {
                let slope = Double(answer.videoKbps - previous.answer.videoKbps) / Double(cap - previous.cap)
                next = slope > 0 ? cap + Int(Double(target.videoKbps - answer.videoKbps) / slope) : cap * target.videoKbps / max(answer.videoKbps, 1)
            } else {
                next = cap * target.videoKbps / max(answer.videoKbps, 1)
            }
            let rounded = roundUp(max(next, 200))
            guard !tried.contains(where: { $0.cap == rounded }) else { break }
            cap = rounded
        }
        let sized = tried.filter { $0.answer.height == target.height }
        let best = sized.min { abs($0.answer.videoKbps - target.videoKbps) < abs($1.answer.videoKbps - target.videoKbps) }
        return best ?? tried[tried.count - 1]
    }

    /// Up to the next 50 kbit/s.
    static func roundUp(_ kbps: Int) -> Int {
        (kbps + 49) / 50 * 50
    }
}
