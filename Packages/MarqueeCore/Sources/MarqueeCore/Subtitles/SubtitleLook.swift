import Foundation

/// How text subtitles look over the video, saved per profile. Lengths are pixels of a 1080-line picture
/// and scale with the picture's height; percentages are whole numbers.
public struct SubtitleLook: Sendable, Equatable, Codable {
    /// The preset the look was last set to. Changing any field it defines makes the look Custom, and
    /// Reset to Preset returns to it.
    public var preset = Preset.blend
    public var font = Font.standard
    public var isBold = true
    /// Text size against the standard line, 5.5 % of the picture's height.
    public var size = 100
    public var colour = TextColour.white
    public var opacity = 90
    public var edge = Edge.softShadow
    public var edgeWidth = 2
    public var background = Background.none
    public var backgroundColour = BoxColour.black
    public var backgroundOpacity = 75
    /// Zero is square corners.
    public var cornerRadius = 0
    public var padding = 6
    public var anchor = Anchor.bottom
    /// From the picture's top or bottom edge to the nearest line.
    public var edgeDistance = 100
    public var lineSpacing = 100
    /// A softened white that never reads as the brightest thing on screen.
    public var blendsWithVideo = true
    public var reveal = Reveal.off
    /// Draws a styled file's own colours and fonts; false draws it in this look too.
    public var keepsFileStyling = true

    public init() {}

    public enum Preset: String, Sendable, Codable, CaseIterable {
        case blend, appleTV, classic, netflix, outline, largePrint, highContrast, marquee
    }

    public enum Font: String, Sendable, Codable, CaseIterable {
        case standard, serif, mono, legible
    }

    public enum TextColour: String, Sendable, Codable, CaseIterable {
        case white, softWhite, yellow, cyan, green, pink
    }

    public enum Edge: String, Sendable, Codable, CaseIterable {
        case none, outline, dropShadow, raised, depressed, softShadow
    }

    public enum Background: String, Sendable, Codable, CaseIterable {
        /// No box.
        case none
        /// A box behind each line.
        case lineBox
        /// One box behind the whole cue.
        case window
    }

    public enum BoxColour: String, Sendable, Codable, CaseIterable {
        case black, plum, slate, brown
    }

    public enum Anchor: String, Sendable, Codable, CaseIterable {
        case bottom, top
    }

    public enum Reveal: String, Sendable, Codable, CaseIterable {
        case off, word, line
    }

    public static let sizes = [75, 85, 100, 115, 130, 150, 175, 200]
    public static let opacities = [25, 50, 75, 90, 100]
    public static let edgeWidths = [1, 2, 3, 4, 5, 6]
    public static let cornerRadii = [0, 4, 8, 12, 16, 24]
    public static let paddings = [0, 4, 6, 10, 16, 24]
    public static let edgeDistances = [40, 60, 80, 100, 130, 160, 200]
    public static let lineSpacings = [80, 90, 100, 115, 130, 150]

    public init(preset: Preset) {
        self.init()
        apply(preset)
    }

    /// Every field the preset defines; reveal and file styling stay, since they are about the text rather than
    /// the look.
    public mutating func apply(_ preset: Preset) {
        let (reveal, keepsFileStyling) = (reveal, keepsFileStyling)
        self = SubtitleLook()
        self.reveal = reveal
        self.keepsFileStyling = keepsFileStyling
        self.preset = preset
        blendsWithVideo = preset == .blend
        switch preset {
        case .blend:
            break
        case .appleTV:
            opacity = 100
        case .classic:
            font = .mono
            isBold = false
            opacity = 100
            edge = .none
            background = .lineBox
            backgroundOpacity = 100
        case .netflix:
            opacity = 100
            edge = .dropShadow
            edgeWidth = 3
        case .outline:
            opacity = 100
            edge = .outline
            edgeWidth = 4
        case .largePrint:
            font = .legible
            size = 150
            opacity = 100
            edge = .outline
            edgeWidth = 3
        case .highContrast:
            font = .legible
            colour = .yellow
            opacity = 100
            edge = .outline
            edgeWidth = 2
            background = .lineBox
            backgroundOpacity = 90
            cornerRadius = 8
        case .marquee:
            opacity = 100
            edge = .outline
            edgeWidth = 1
        }
    }

    /// Some field differs from the preset's own settings.
    public var isCustom: Bool {
        !SubtitleLook(preset: preset).matches(self)
    }

    /// The preset's own settings again.
    public mutating func resetToPreset() {
        apply(preset)
    }

    /// Same appearance; reveal and file styling are not compared.
    private func matches(_ other: SubtitleLook) -> Bool {
        var a = self, b = other
        (a.preset, b.preset) = (.blend, .blend)
        (a.reveal, b.reveal) = (.off, .off)
        (a.keepsFileStyling, b.keepsFileStyling) = (true, true)
        return a == b
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        // A look saved before presets existed has no preset key; it starts over from the default look.
        guard c.contains(.preset) else { return }
        preset = value(.preset) ?? preset
        font = value(.font) ?? font
        isBold = value(.isBold) ?? isBold
        size = value(.size) ?? size
        colour = value(.colour) ?? colour
        opacity = value(.opacity) ?? opacity
        edge = value(.edge) ?? edge
        edgeWidth = value(.edgeWidth) ?? edgeWidth
        background = value(.background) ?? background
        backgroundColour = value(.backgroundColour) ?? backgroundColour
        backgroundOpacity = value(.backgroundOpacity) ?? backgroundOpacity
        cornerRadius = value(.cornerRadius) ?? cornerRadius
        padding = value(.padding) ?? padding
        anchor = value(.anchor) ?? anchor
        edgeDistance = value(.edgeDistance) ?? edgeDistance
        lineSpacing = value(.lineSpacing) ?? lineSpacing
        blendsWithVideo = value(.blendsWithVideo) ?? blendsWithVideo
        reveal = value(.reveal) ?? reveal
        keepsFileStyling = value(.keepsFileStyling) ?? keepsFileStyling
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset, forKey: .preset)
        try c.encode(font, forKey: .font)
        try c.encode(isBold, forKey: .isBold)
        try c.encode(size, forKey: .size)
        try c.encode(colour, forKey: .colour)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(edge, forKey: .edge)
        try c.encode(edgeWidth, forKey: .edgeWidth)
        try c.encode(background, forKey: .background)
        try c.encode(backgroundColour, forKey: .backgroundColour)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(padding, forKey: .padding)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(edgeDistance, forKey: .edgeDistance)
        try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(blendsWithVideo, forKey: .blendsWithVideo)
        try c.encode(reveal, forKey: .reveal)
        try c.encode(keepsFileStyling, forKey: .keepsFileStyling)
    }

    private enum CodingKeys: String, CodingKey {
        case preset, font, isBold, size, colour, opacity, edge, edgeWidth, background, backgroundColour, backgroundOpacity
        case cornerRadius, padding, anchor, edgeDistance, lineSpacing, blendsWithVideo, reveal, keepsFileStyling
    }
}
