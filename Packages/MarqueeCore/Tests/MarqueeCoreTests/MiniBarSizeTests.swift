import Testing
@testable import MarqueeCore

struct MiniBarSizeTests {
    /// The phone's bar: 48 pt slim, its picture 6 pt in from the top and bottom.
    private func bar(width: Double) -> MiniBarSize {
        MiniBarSize(slim: 48, margin: 6, width: width)
    }

    @Test func thePictureGrowsWithTheBarInItsShape() {
        let size = bar(width: 358)

        #expect(size.pictureHeight(inBar: 48) == 36)
        #expect(abs(size.pictureWidth(inBar: 48) - 64) < 1e-9)
        #expect(size.pictureHeight(inBar: 96) == 84)
        #expect(abs(size.pictureWidth(inBar: 96) / 84 - MiniBarSize.pictureAspect) < 1e-9)
    }

    @Test func theTallestBarIsLimitedByTheWidthAndByTwiceTheSlimHeight() {
        #expect(bar(width: 0).tallest == 48)
        #expect(bar(width: 100).tallest == 48)
        #expect(abs(bar(width: 300).tallest - 79.5) < 1e-9)
        #expect(bar(width: 800).tallest == 96)
    }

    @Test func aBarLetGoNearTheSlimHeightGoesBackToIt() {
        let size = bar(width: 358)

        #expect(size.rest(30) == 48)
        #expect(size.rest(56) == 48)
        #expect(size.rest(57) == 57)
        #expect(size.rest(500) == size.tallest)
        #expect(size.held(500) == size.tallest)
    }

    @Test func theFractionRunsFromSlimToTheTallest() {
        let size = bar(width: 800)

        #expect(size.fraction(48) == 0)
        #expect(size.fraction(72) == 0.5)
        #expect(size.fraction(200) == 1)
        #expect(bar(width: 100).fraction(90) == 0)
    }
}
