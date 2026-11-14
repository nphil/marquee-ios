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
    /// A round button standing in the navigation bar without its glass capsule (Home's profile and
    /// remote buttons). The bar gives an item 44 pt of height, so the ring is exactly that and nothing
    /// overflows the item's bounds, which a sheet's zoom clips to.
    static let barButton: CGFloat = 44
    static let rowMin: CGFloat = 56
    /// Minimum poster and theme-tile width in an adaptive grid: 3 columns at 390 pt, 2 at 320 pt.
    static let gridMin: CGFloat = 104
    /// The player's round controls (DESIGN §8.6).
    static let control: CGFloat = 56
    /// A player control's glyph at the default text size: 40% of the circle.
    static let controlGlyph: CGFloat = 22
    /// The most Dynamic Type grows a player glyph: half the circle.
    static let controlGlyphMax: CGFloat = 28
    /// The icon column of a menu row at the default text size; it scales with Dynamic Type.
    static let menuGlyph: CGFloat = 28
    /// The link code Linked Phones shows (DESIGN §8.10): big enough for a phone held at arm's length.
    static let linkCode: CGFloat = 240
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

/// The glasses screen (DESIGN §8.9): a 1920 × 1080 canvas at scale 1. Its edges look soft through
/// the lenses, so content keeps well inside the margins, and everything is sized to be read at a glance.
enum GlassesCanvas {
    static let width: CGFloat = 1920
    static let height: CGFloat = 1080
    static let marginX: CGFloat = 144
    static let marginY: CGFloat = 88
    /// Between rows; between a row's title and its tiles; between tiles; between a tile and its caption.
    static let rowGap: CGFloat = 48
    static let titleGap: CGFloat = 16
    static let tileGap: CGFloat = 32
    static let captionGap: CGFloat = 16
    /// Line boxes: the page title, a row title, a caption and the line under it, the focused title's two lines.
    static let header: CGFloat = 72
    static let rowTitle: CGFloat = 56
    static let caption: CGFloat = 40
    static let subcaption: CGFloat = 32
    static let focusLine: CGFloat = 104
    static let poster = CGSize(width: 220, height: 330)
    static let landscape = CGSize(width: 400, height: 225)
    /// A library, tab or option: text on a raised surface.
    static let card = CGSize(width: 400, height: 120)
    static let key = CGSize(width: 96, height: 96)
    static let logo: CGFloat = 120
    /// Large status glyphs: play and pause, a notice's symbol.
    static let glyph: CGFloat = 120
    /// The focused tile grows by this much, and its ring is this wide. The rows keep `focusRoom` above
    /// the focused tile so the growth is not cut off.
    static let focusScale: CGFloat = 1.08
    static let focusRing: CGFloat = 6
    static let focusRoom: CGFloat = 24
    static let radius: CGFloat = 24
    static let pill: CGFloat = 60
    /// The opened title: its text block, the width its overview wraps at, and the backdrop behind it.
    static let heroHeight: CGFloat = 330
    static let overviewWidth: CGFloat = 1100
    static let backdrop = CGSize(width: 1200, height: 675)
    /// The player's track panel and the options panel, and one line in them.
    static let panelWidth: CGFloat = 760
    static let option: CGFloat = 88
    static let barHeight: CGFloat = 10
    static let volumeWidth: CGFloat = 380
}
