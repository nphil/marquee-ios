/// How tall the mini player's bar may be and where a drag leaves it (DESIGN §8.6.1). The picture grows
/// with the bar and keeps its 16:9 shape and its margin above and below.
public struct MiniBarSize: Equatable, Sendable {
    /// The picture's width over its height.
    public static let pictureAspect = 16.0 / 9.0
    /// The most of the bar's width the picture may take, so the title keeps its room beside it.
    static let pictureShare = 0.4
    /// How many times its slim height the bar may grow to.
    static let growth = 2.0
    /// A bar let go this close to the slim height, in points, goes back to it.
    static let snap = 8.0

    /// The bar's height before it is dragged taller, in points.
    public let slim: Double
    /// The space above and below the picture, in points.
    public let margin: Double
    /// The tallest the bar gets, in points.
    public let tallest: Double

    /// The limits of a bar `width` points wide. A width of zero, as before the bar is measured, allows no
    /// growth.
    public init(slim: Double, margin: Double, width: Double) {
        self.slim = slim
        self.margin = margin
        let byWidth = margin * 2 + width * Self.pictureShare / Self.pictureAspect
        tallest = max(slim, min(slim * Self.growth, byWidth))
    }

    /// `height` kept between the slim height and the tallest, as a drag holds the bar.
    public func held(_ height: Double) -> Double {
        min(max(height, slim), tallest)
    }

    /// Where a bar let go at `height` comes to rest: between the limits, and at the slim height when it is
    /// close to it.
    public func rest(_ height: Double) -> Double {
        let kept = held(height)
        return kept - slim <= Self.snap ? slim : kept
    }

    /// How far a bar `height` tall is from slim (0) to the tallest (1).
    public func fraction(_ height: Double) -> Double {
        tallest > slim ? (held(height) - slim) / (tallest - slim) : 0
    }

    /// The picture's height in a bar `height` tall.
    public func pictureHeight(inBar height: Double) -> Double {
        max(height - margin * 2, 0)
    }

    /// The picture's width in a bar `height` tall.
    public func pictureWidth(inBar height: Double) -> Double {
        pictureHeight(inBar: height) * Self.pictureAspect
    }
}
