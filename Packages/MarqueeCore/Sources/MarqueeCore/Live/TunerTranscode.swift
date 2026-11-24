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

        public init(name: String, codec: String, maxHeight: Int?, progressive: Bool, kbps: Int? = nil) {
            self.name = name
            self.codec = codec
            self.maxHeight = maxHeight
            self.progressive = progressive
            self.kbps = kbps
        }
    }

    /// `profile` nil: the original stream is requested, for `reason`. `source` is the channel's known height in lines.
    public struct Decision: Equatable, Sendable {
        public var profile: Profile?
        public var reason: String
        public var source: Int?
        public var asked: Bool { profile != nil }
    }

    /// The tuner's `mobile` profile: H.264, 1280×720 at most. Used while the TV publishes no profiles.
    public static let builtIn = Profile(name: "mobile", codec: "h264", maxHeight: 720, progressive: true)
    public static let shared = TunerTranscode()
    private static let offerLife: TimeInterval = 60

    private let lock = NSLock()
    private var declined = Set<String>()
    private var heights: [String: Int] = [:]
    private var learning = Set<String>()
    private var offers: [String: (profiles: [Profile]?, at: Date)] = [:]

    public init() {}

    /// What the tune of `channel` on `tuner` asks for. A tune that does not limit the picture learns the channel's height
    /// from its pictures (`noted`); the tallest seen counts, so a slate cannot pass for the station.
    public func decide(
        isLuma: Bool, tuner: String, channel: String, offer: [Profile]?, canDecode: (_ codec: String, _ height: Int?) -> Bool
    ) -> Decision {
        guard isLuma else { return Decision(profile: nil, reason: "not-luma", source: nil) }
        let key = Self.key(tuner, channel)
        return lock.withLock {
            let source = heights[key]
            if declined.contains(tuner) { return Decision(profile: nil, reason: "declined", source: source) }
            let (profile, reason) = Self.choose(offer: offer, source: source, canDecode: canDecode)
            if profile?.maxHeight == nil {
                learning.insert(key)
                heights[key] = nil
            } else {
                learning.remove(key)
            }
            return Decision(profile: profile, reason: reason, source: source)
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
    /// `builtIn` for a source of 720 lines or fewer.
    public static func choose(
        offer: [Profile]?, source: Int?, canDecode: (_ codec: String, _ height: Int?) -> Bool
    ) -> (Profile?, String) {
        guard let offer else {
            guard let source else { return (nil, "unknown") }
            if source > builtIn.maxHeight! { return (nil, "hd") }
            return canDecode(builtIn.codec, source) ? (builtIn, "sd") : (nil, "no-decoder")
        }
        let best = offer.first { profile in
            guard profile.progressive else { return false }
            if let limit = profile.maxHeight, source.map({ limit < $0 }) ?? true { return false }
            return canDecode(profile.codec, profile.maxHeight ?? source)
        }
        return (best, best == nil ? "no-profile" : "profile")
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
                progressive: entry["progressive"] as? Bool == true, kbps: (entry["kbps"] as? NSNumber)?.intValue
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
