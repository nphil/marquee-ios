import Foundation

/// Another client took LumaTV's tuner from this one: an entry of the tuner's `status.json` `displaced` list,
/// kept for 60 s after the takeover. Older TVs have no such list.
public struct TunerDisplacement: Sendable, Hashable {
    /// Who took the tuner: a client's name, or the TV's own.
    public var by: String
    public var byKind: Kind
    public var at: Date

    public enum Kind: String, Sendable { case app, tv }

    /// "Nate's iPad is now using the TV tuner." The TV's own use has its own sentence.
    public var message: String {
        if byKind == .tv { return "The TV is now using its tuner." }
        return by.isEmpty ? "Another device is now using the TV tuner." : "\(by) is now using the TV tuner."
    }
}

public enum TunerTakeover {
    /// The TV keeps a displaced client listed this long.
    public static let window: TimeInterval = 60
    /// The TV reads at most this many characters of a client's name.
    public static let nameLimit = 40

    /// `name` as the TV records it: trimmed and cut to `nameLimit`, which is also how an entry is matched.
    public static func clientName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
    }

    /// `streamURL` with `?device=<name>`. A name's `+` and `&` are encoded, which `URLQueryItem` leaves alone.
    public static func naming(_ url: URL, as name: String) -> URL {
        let value = clientName(name)
        guard !value.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.percentEncodedQuery = "device=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        return parts.url ?? url
    }

    /// The entry of `body` (`status.json`) that names this client and is no older than `window`; the newest
    /// when several do. Anything else in the document, or a document that is not an object, answers nil.
    public static func displacement(in body: Data, clientName name: String, now: Date = Date()) -> TunerDisplacement? {
        let mine = clientName(name)
        guard !mine.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = root["displaced"] as? [[String: Any]] else { return nil }
        return entries.compactMap { entry -> TunerDisplacement? in
            guard entry["name"] as? String == mine, let millis = (entry["at"] as? NSNumber)?.doubleValue else { return nil }
            let at = Date(timeIntervalSince1970: millis / 1000)
            guard now.timeIntervalSince(at) <= window else { return nil }
            return TunerDisplacement(
                by: (entry["by"] as? String) ?? "",
                byKind: (entry["byKind"] as? String).flatMap(TunerDisplacement.Kind.init) ?? .app,
                at: at
            )
        }.max { $0.at < $1.at }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Same-frequency sharing on LumaTV's tuner, read from `status.json`: viewers on one RF share a tuner, up to
/// `capacity`; another RF displaces them, or is refused while Plex records. Every field is optional, so an older
/// TV reads as "nothing shared" and keeps today's behaviour.
public enum TunerSharing {
    public static let capacity = 4
    public static let fullMessage = "Four devices are already watching this channel group."
    public static let recordingMessage = "The TV is recording, so its tuner can't change channel right now."

    /// Whether `number` is on the RF a current viewer is on, so tuning it joins that tuner instead of taking it over.
    public static func shares(in body: Data, wanting number: String) -> Bool {
        viewers(in: body, wanting: number) > 0
    }

    /// The sentence for a 503 on the stream request of channel `number`; nil keeps the generic refusal.
    public static func refusalMessage(in body: Data, wanting number: String) -> String? {
        if viewers(in: body, wanting: number) >= capacity { return fullMessage }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let holder = root["holder"] as? [String: Any],
              (holder["name"] as? String)?.localizedCaseInsensitiveContains("plex") == true else { return nil }
        return recordingMessage
    }

    /// Viewers on the RF of `number`: those watching it, or another channel of an RF group that carries it.
    private static func viewers(in body: Data, wanting number: String) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let viewers = root["viewers"] as? [[String: Any]] else { return 0 }
        let group = (root["sameRf"] as? [[String: Any]])?
            .compactMap { $0["channels"] as? [String] }
            .first { $0.contains(number) } ?? [number]
        return viewers.filter { ($0["channel"] as? String).map(group.contains) == true }.count
    }
}
