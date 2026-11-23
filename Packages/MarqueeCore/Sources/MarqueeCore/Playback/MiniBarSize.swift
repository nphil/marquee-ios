/// How tall the mini player's bar is for the width it has, and the picture in it (DESIGN §8.6.1). The
/// picture keeps its 16:9 shape and its margin above and below.
public struct MiniBarSize: Equatable, Sendable {
    /// The picture's width over its height.
    public static let pictureAspect = 16.0 / 9.0
    /// The most of the bar's width the picture may take, so the title keeps its room beside it.
    static let pictureShare = 0.4
    /// How many times `least` the bar may grow to.
    static let growth = 2.0

    /// The bar's height, in points.
    public let height: Double
    /// The space above and below the picture, in points.
    public let margin: Double

    /// The bar `width` points wide: tall enough for a 16:9 picture to take 40% of the width, but between
    /// `least` and twice it. A width of zero, as before the bar is measured, gives `least`.
    public init(least: Double, margin: Double, width: Double) {
        self.margin = margin
        let byWidth = margin * 2 + width * Self.pictureShare / Self.pictureAspect
        height = max(least, min(least * Self.growth, byWidth))
    }

    /// The picture's height.
    public var pictureHeight: Double {
        max(height - margin * 2, 0)
    }

    /// The picture's width.
    public var pictureWidth: Double {
        pictureHeight * Self.pictureAspect
    }
}
