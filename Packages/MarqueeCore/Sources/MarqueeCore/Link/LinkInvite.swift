import Foundation

/// A phone's identity on the link: 16 random bytes made once per iPhone, written as 32 lowercase hex
/// digits. It is also the phone's Bonjour instance name.
public struct LinkID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let length = 16

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.length else { return nil }
        self.bytes = Data(bytes)
    }

    public init?(_ hex: String) {
        guard hex.utf8.count == Self.length * 2, let bytes = Data(linkHex: hex) else { return nil }
        self.bytes = bytes
    }

    public static func random() -> LinkID {
        LinkID(bytes: LinkKeys.randomBytes(length))!
    }

    public var description: String { bytes.linkHex }

    public static func < (lhs: LinkID, rhs: LinkID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public init(from decoder: any Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let id = LinkID(hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a link id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What a phone's pairing code carries: `marquee-link://pair?v=1&id=<id>&n=<name>&s=<secret>`. The
/// secret is 32 random bytes in base64url without padding; it opens the one pairing the showing phone
/// accepts while its code is up.
public struct LinkInvite: Sendable, Hashable {
    public static let scheme = "marquee-link"
    public static let version = 1
    public static let secretLength = 32

    public let id: LinkID
    public let name: String
    public let secret: Data

    public init(id: LinkID, name: String, secret: Data = LinkKeys.randomBytes(LinkInvite.secretLength)) {
        self.id = id
        self.name = LinkName.clean(name)
        self.secret = secret
    }

    /// Nil for anything but a version 1 link code with a valid id and secret.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme, components.host?.lowercased() == "pair",
              let items = components.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == String(Self.version), let id = value("id").flatMap(LinkID.init),
              let secret = value("s").flatMap(Data.init(base64URL:)), secret.count == Self.secretLength
        else { return nil }
        self.init(id: id, name: value("n") ?? "", secret: secret)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "id", value: id.description),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "s", value: secret.base64URL),
        ]
        // A scheme, a host and query items always make a URL.
        return components.url!
    }
}

/// A phone's name as the other phone shows it: one line, at most 40 characters.
public enum LinkName {
    public static let maxLength = 40

    public static func clean(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let line = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}

/// A phone this one is linked with, as kept in the Keychain.
public struct LinkedPhone: Sendable, Hashable, Codable, Identifiable {
    public let id: LinkID
    public var name: String
    /// The key both phones derived when they linked (`LinkKeys.linkKey`); every session's key comes from it.
    public let key: Data
    public let linkedAt: Date

    public init(id: LinkID, name: String, key: Data, linkedAt: Date) {
        self.id = id
        self.name = name
        self.key = key
        self.linkedAt = linkedAt
    }
}

extension Data {
    init?(linkHex hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let nibble: UInt8
            switch character {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = character - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = character - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = character - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let value = high {
                bytes.append(value << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { return nil }
        self.init(bytes)
    }

    var linkHex: String {
        let digits = Array("0123456789abcdef".utf8)
        var text = [UInt8]()
        text.reserveCapacity(count * 2)
        for byte in self {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
