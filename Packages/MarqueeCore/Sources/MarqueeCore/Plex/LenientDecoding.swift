import Foundation

// Plex sends one attribute as a number, a string or a boolean depending on server version and endpoint
// ("1", 1, true). Every field is read leniently, and a malformed field never fails its whole item.
extension KeyedDecodingContainer {
    func string(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func int(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Self.integer(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return Int(trimmed) ?? Double(trimmed).flatMap(Self.integer)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    func double(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func bool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true": return true
            case "0", "false", "": return false
            default: return nil
            }
        }
        return nil
    }

    /// Plex servers send Unix seconds; plex.tv sends ISO 8601.
    func date(_ key: Key) -> Date? {
        if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    func list<T: Decodable>(_ key: Key) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }

    /// The `tag` names of a tag list such as `Genre` or `Director`.
    func tags(_ key: Key) -> [String] {
        let tags: [PlexTag] = list(key)
        return tags.compactMap(\.tag)
    }

    private static func integer(_ value: Double) -> Int? {
        value.isFinite && abs(value) < 9.0e18 ? Int(value) : nil
    }
}

struct PlexTag: Decodable {
    let tag: String?
}
