import CoreGraphics

/// Space, size and radius tokens from DESIGN §4.1 and §4.2.
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s7: CGFloat = 32
    static let s8: CGFloat = 40

    /// Screen inset, added to the safe area, never instead of it.
    static let inset: CGFloat = 16
}

enum Size {
    static let target: CGFloat = 48
    static let rowMin: CGFloat = 56
    /// Minimum poster and theme-tile width in an adaptive grid: 3 columns at 390 pt, 2 at 320 pt.
    static let gridMin: CGFloat = 104
    /// The player's round controls (DESIGN §8.6).
    static let control: CGFloat = 56
    /// A player control's glyph at the default text size: 40% of the circle.
    static let controlGlyph: CGFloat = 22
    /// The most Dynamic Type grows a player glyph: half the circle.
    static let controlGlyphMax: CGFloat = 28
}

enum Radius {
    static let sheet: CGFloat = 28
    static let card: CGFloat = 24
    /// Art whose short side is 96 pt or more.
    static let tile: CGFloat = 20
    static let row: CGFloat = 18
    /// Art whose short side is under 96 pt, and text fields.
    static let control: CGFloat = 14

    /// Inner radius for a shape inset inside another (DESIGN §4.2).
    static func inner(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 6)
    }
}
