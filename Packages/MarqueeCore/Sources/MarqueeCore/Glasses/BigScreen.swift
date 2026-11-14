import Foundation

/// What an external display is. iOS reports a pixel size and a refresh rate, never whether the picture
/// goes to birdbath glasses or a television, so the person says, once per display.
public enum DisplayKind: String, Codable, CaseIterable, Sendable {
    case glasses
    case tv

    public var title: String {
        switch self {
        case .glasses: "XR Glasses"
        case .tv: "TV"
        }
    }
}

/// What a connected external display is used for. The first connection asks, and the answer stays
/// until it is changed in the plugin's settings.
public enum BigScreenUse: String, Codable, CaseIterable, Sendable {
    case ask
    /// Marquee draws its own big-screen UI and the phone becomes the remote. The raw value is what 0.1.36
    /// stored when only glasses existed.
    case marquee = "glasses"
    /// The display shows a copy of the phone, as iOS does without the plugin.
    case mirror

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .marquee: "Use Marquee’s TV Screen"
        case .mirror: "Mirror"
        }
    }
}

/// A connected display as iOS describes it. The key tells displays apart between connections.
public struct DisplayIdentity: Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Hertz.
    public var refreshRate: Int
    /// The display's own name where iOS exposes one, such as the audio route over HDMI.
    public var name: String?

    public init(pixelWidth: Int, pixelHeight: Int, refreshRate: Int, name: String? = nil) {
        // Landscape whichever way the display reports it.
        self.pixelWidth = max(pixelWidth, pixelHeight)
        self.pixelHeight = min(pixelWidth, pixelHeight)
        self.refreshRate = refreshRate
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
    }

    public var key: String { "\(pixelWidth)x\(pixelHeight)@\(refreshRate)" }

    /// "3840 × 2160", or nil when the display reported no size.
    public var sizeLabel: String? {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : nil
    }

    /// What the first-connection question calls the display: its name, else its size, else just "this display".
    public var subject: String {
        if let name { return "“\(name)”" }
        if let sizeLabel { return "this \(sizeLabel) display" }
        return "this display"
    }

    public var question: String { "Use Marquee on \(subject)?" }
}

/// One display whose answer is kept.
public struct RememberedDisplay: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    /// As last seen, for the list in Settings.
    public var name: String?
    public var sizeLabel: String?
    public var kind: DisplayKind
    /// `.marquee` or `.mirror`; a display that is still to be asked is not remembered.
    public var use: BigScreenUse

    public var id: String { key }

    public var title: String { name ?? sizeLabel ?? "Display" }

    public var summary: String {
        let used = use == .mirror ? "Mirrors the phone" : "Marquee’s screen"
        return "\(kind.title) · \(used)"
    }
}

/// The answers kept per display, so glasses and a TV can have different ones. `.ask` is never kept.
public struct DisplayMemory: Codable, Equatable, Sendable {
    public private(set) var displays: [RememberedDisplay] = []

    public init() {}

    public func entry(for identity: DisplayIdentity) -> RememberedDisplay? {
        displays.first { $0.key == identity.key }
    }

    public mutating func remember(_ identity: DisplayIdentity, kind: DisplayKind, use: BigScreenUse) {
        guard use != .ask else { return }
        let entry = RememberedDisplay(key: identity.key, name: identity.name, sizeLabel: identity.sizeLabel, kind: kind, use: use)
        if let index = displays.firstIndex(where: { $0.key == entry.key }) {
            displays[index] = entry
        } else {
            displays.append(entry)
        }
    }

    public mutating func forget(key: String) {
        displays.removeAll { $0.key == key }
    }
}

/// What to do with a display that has just connected.
public enum DisplayOutcome: Equatable, Sendable {
    case ask
    case marquee(DisplayKind)
    case mirror

    /// A remembered answer for this display wins; otherwise the page's "When a Display Connects" does, with
    /// `defaultKind` for a display that was not told apart yet.
    public static func decide(
        for identity: DisplayIdentity, memory: DisplayMemory, use: BigScreenUse, defaultKind: DisplayKind
    ) -> DisplayOutcome {
        if let known = memory.entry(for: identity) {
            return known.use == .mirror ? .mirror : .marquee(known.kind)
        }
        switch use {
        case .ask: return .ask
        case .marquee: return .marquee(defaultKind)
        case .mirror: return .mirror
        }
    }
}

/// How the big screen is laid out on a display. Every size is in design points: the canvas is 1080 high on
/// any display and the app scales it to the display's own pixels, so the layout tokens stay proportional on
/// a 4K TV.
public struct BigScreenLayout: Equatable, Sendable {
    public static let designHeight = 1080.0
    /// The share of each side a TV keeps clear, as overscan can cut that much off.
    public static let tvSafeMargin = 0.05
    /// A TV wider or narrower than this is letterboxed.
    public static let tvAspects = (4.0 / 3.0)...(64.0 / 27.0)

    public let kind: DisplayKind
    public let width: Double
    public let height: Double
    public let marginX: Double
    public let marginY: Double

    /// Glasses: 1920 × 1080 whatever they report, with wide margins since the lens edges are soft.
    public static let glasses = BigScreenLayout(kind: .glasses, width: 1920, height: designHeight, marginX: 144, marginY: 88)

    public init(kind: DisplayKind, pixelWidth: Int, pixelHeight: Int) {
        switch kind {
        case .glasses:
            self = .glasses
        case .tv:
            let aspect = pixelWidth > 0 && pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 16.0 / 9.0
            let clamped = min(max(aspect, Self.tvAspects.lowerBound), Self.tvAspects.upperBound)
            let width = (Self.designHeight * clamped).rounded()
            self.init(
                kind: .tv, width: width, height: Self.designHeight,
                marginX: (width * Self.tvSafeMargin).rounded(), marginY: (Self.designHeight * Self.tvSafeMargin).rounded()
            )
        }
    }

    private init(kind: DisplayKind, width: Double, height: Double, marginX: Double, marginY: Double) {
        self.kind = kind
        self.width = width
        self.height = height
        self.marginX = marginX
        self.marginY = marginY
    }

    /// Black is see-through on birdbath glasses; a TV shows the theme's own canvas.
    public var usesBlackCanvas: Bool { kind == .glasses }

    /// How much the canvas grows to fill a display of this many points, without cropping.
    public func scale(fitting displayWidth: Double, _ displayHeight: Double) -> Double {
        min(displayWidth / width, displayHeight / height)
    }
}
