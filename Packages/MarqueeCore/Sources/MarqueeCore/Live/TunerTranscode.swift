import Foundation

/// A LumaTV tuner can convert an antenna channel for a client that asks with `?transcode=<profile>`. The profiles
/// come from the tuner's `status.json` (`transcode.profiles`) and `choose` picks the best one for this phone. A TV
/// that publishes none is asked for `builtIn` only when the channel is known to be 720 lines or fewer, so the picture
/// is never reduced. The tuner may still answer with the broadcast as it is, which plays as before. A tuner that
/// fails the request is asked for the broadcast for the rest of the app run.
public final class TunerTranscode: @unchecked Sendable {
    public struct Profile: Equatable, Sendable {
        public var name: String
        /// `h264` or `hevc`.
        public var codec: String
        /// Nil keeps the source size.
        public var maxHeight: Int?
        public var progressive: Bool
        public var kbps: Int?
        /// Pictures a second the profile makes of an interlaced station; nil keeps the field rate (about 60).
        public var interlacedFps: Int?

        public init(name: String, codec: String, maxHeight: Int?, progressive: Bool, kbps: Int? = nil, interlacedFps: Int? = nil) {
            self.name = name
            self.codec = codec
            self.maxHeight = maxHeight
            self.progressive = progressive
            self.kbps = kbps
            self.interlacedFps = interlacedFps
        }
    }

    /// `profile` nil: the original stream is requested, for `reason`. `source` is the channel's known height in lines.
    public struct Decision: Equatable, Sendable {
        public var profile: Profile?
        public var reason: String
        public var source: Int?
        /// Whether the channel is interlaced, when known; for the log.
        public var interlaced: Bool?
        /// The "Prefer smooth motion" setting this decision was made under; for the log.
        public var smooth: Bool
        public var asked: Bool { profile != nil }

        public init(profile: Profile?, reason: String, source: Int?, interlaced: Bool? = nil, smooth: Bool = false) {
            self.profile = profile
            self.reason = reason
            self.source = source
            self.interlaced = interlaced
            self.smooth = smooth
        }
    }

    /// The tuner's `mobile` profile: H.264, 1280×720 at most, 30 pictures a second from an interlaced station. Used
    /// while the TV publishes no profiles.
    public static let builtIn = Profile(name: "mobile", codec: "h264", maxHeight: 720, progressive: true, interlacedFps: 30)
    public static let shared = TunerTranscode()
    private static let offerLife: TimeInterval = 60

    private let lock = NSLock()
    private var declined = Set<String>()
    private var heights: [String: Int] = [:]
    private var learning = Set<String>()
    private var scans: [String: Bool] = [:]
    private var learningScan = Set<String>()
    private var offers: [String: (profiles: [Profile]?, at: Date)] = [:]

    public init() {}

    /// What the tune of `channel` on `tuner` asks for. A tune that does not limit the picture learns the channel's height
    /// from its pictures (`noted`); the tallest seen counts, so a slate cannot pass for the station. A tune of the
    /// original stream learns whether the channel is interlaced (`notedScan`) in the same way. `lineupInterlaced` is
    /// the tuner's own word for the channel and wins over what was learned. `smooth` is "Prefer smooth motion".
    public func decide(
        isLuma: Bool, tuner: String, channel: String, offer: [Profile]?, smooth: Bool, lineupInterlaced: Bool? = nil,
        canDecode: (_ codec: String, _ height: Int?) -> Bool
    ) -> Decision {
        guard isLuma else { return Decision(profile: nil, reason: "not-luma", source: nil, smooth: smooth) }
        let key = Self.key(tuner, channel)
        return lock.withLock {
            let source = heights[key]
            let interlaced = lineupInterlaced ?? scans[key]
            if declined.contains(tuner) {
                return Decision(profile: nil, reason: "declined", source: source, interlaced: interlaced, smooth: smooth)
            }
            let (profile, reason) = Self.choose(
                offer: offer, source: source, interlaced: interlaced, smooth: smooth, canDecode: canDecode
            )
            if profile?.maxHeight == nil {
                learning.insert(key)
                heights[key] = nil
            } else {
                learning.remove(key)
            }
            if profile == nil {
                learningScan.insert(key)
                scans[key] = nil
            } else {
                learningScan.remove(key)
            }
            return Decision(profile: profile, reason: reason, source: source, interlaced: interlaced, smooth: smooth)
        }
    }

    /// A picture of a tune of `channel` that asked for no profile was `interlaced` or not; one interlaced picture
    /// makes the channel interlaced.
    public func notedScan(interlaced: Bool, tuner: String, channel: String) {
        let key = Self.key(tuner, channel)
        lock.withLock {
            if learningScan.contains(key) { scans[key] = (scans[key] ?? false) || interlaced }
        }
    }

    /// A picture of `height` lines reached the screen of a tune of `channel` that did not limit it.
    public func noted(height: Int, tuner: String, channel: String) {
        let key = Self.key(tuner, channel)
        lock.withLock {
            if learning.contains(key) { heights[key] = max(heights[key] ?? 0, height) }
        }
    }

    public func decline(tuner: String) {
        lock.withLock { _ = declined.insert(tuner) }
    }

    /// The profiles `tuner` published within the last minute; `nil` when never read or stale. A tuner that published
    /// none answers `.some(nil)`.
    public func cachedOffer(tuner: String, now: Date = Date()) -> [Profile]?? {
        lock.withLock {
            guard let entry = offers[tuner], now.timeIntervalSince(entry.at) < Self.offerLife else { return nil }
            return .some(entry.profiles)
        }
    }

    public func store(offer: [Profile]?, tuner: String, now: Date = Date()) {
        lock.withLock { offers[tuner] = (offer, now) }
    }

    /// `url` with `transcode=<profile>` added to its query.
    public static func asking(_ url: URL, _ profile: Profile) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let name = profile.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        parts.percentEncodedQuery = (parts.percentEncodedQuery.map { $0 + "&" } ?? "") + "transcode=" + name
        return parts.url ?? url
    }

    /// The best profile of `offer` for a channel of `source` lines, with the reason when there is none. A profile
    /// qualifies when it keeps the resolution (no limit, or a limit at or above the source; an unknown source only
    /// suits no limit), is progressive and has a decoder here; the tuner's order breaks ties. Without an `offer` it is
    /// `builtIn` for a source of 720 lines or fewer. With `smooth`, a profile that has an `interlacedFps` (it turns
    /// about 60 fields a second into fewer pictures) does not qualify for a channel that is interlaced or not known
    /// to be progressive; the reason is then `motion`.
    public static func choose(
        offer: [Profile]?, source: Int?, interlaced: Bool? = nil, smooth: Bool = false,
        canDecode: (_ codec: String, _ height: Int?) -> Bool
    ) -> (Profile?, String) {
        let keepsMotion = { (profile: Profile) in !smooth || profile.interlacedFps == nil || interlaced == false }
        guard let offer else {
            guard let source else { return (nil, "unknown") }
            if source > builtIn.maxHeight! { return (nil, "hd") }
            if !keepsMotion(builtIn) { return (nil, "motion") }
            return canDecode(builtIn.codec, source) ? (builtIn, "sd") : (nil, "no-decoder")
        }
        var skipped = false
        let best = offer.first { profile in
            guard profile.progressive else { return false }
            if let limit = profile.maxHeight, source.map({ limit < $0 }) ?? true { return false }
            guard canDecode(profile.codec, profile.maxHeight ?? source) else { return false }
            if !keepsMotion(profile) {
                skipped = true
                return false
            }
            return true
        }
        return (best, best != nil ? "profile" : skipped ? "motion" : "no-profile")
    }

    /// The profiles in a tuner's `status.json`: nil when it publishes none (an older TV), empty when it is off.
    /// Unknown fields are ignored and every field is optional.
    public static func offer(in body: Data) -> [Profile]? {
        guard let root = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["transcode"] as? [String: Any] else {
            return nil
        }
        if root["enabled"] as? Bool == false { return [] }
        guard let list = root["profiles"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty, let codec = (entry["codec"] as? String)?.lowercased() else {
                return nil
            }
            return Profile(
                name: name, codec: codec, maxHeight: (entry["maxHeight"] as? NSNumber)?.intValue,
                progressive: entry["progressive"] as? Bool == true, kbps: (entry["kbps"] as? NSNumber)?.intValue,
                interlacedFps: (entry["interlacedFps"] as? NSNumber)?.intValue
            )
        }
    }

    /// Whether a failed tune that asked for a profile is retried once without it: the tuner refused the request (400,
    /// 503) or sent no picture. A 503 the tuner explains in `status.json` (full, or the TV recording) is its answer,
    /// not the conversion's.
    public static func retriesWithoutTranscode(asked: Bool, status: Int?, noPicture: Bool, sharingRefusal: Bool) -> Bool {
        asked && !sharingRefusal && (noPicture || status == 400 || status == 503)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func key(_ tuner: String, _ channel: String) -> String { tuner + "|" + channel }
}
