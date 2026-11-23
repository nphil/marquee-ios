import Testing
@testable import MarqueeCore

struct MiniBarSizeTests {
    /// The phone's bar: at least 48 pt, its picture 6 pt in from the top and bottom.
    private func bar(width: Double) -> MiniBarSize {
        MiniBarSize(least: 48, margin: 6, width: width)
    }

    @Test func theBarIsAsTallAsAPictureTakingFortyPercentOfItsWidthAllows() {
        #expect(abs(bar(width: 300).height - 79.5) < 1e-9)
        #expect(abs(bar(width: 350).height - 90.75) < 1e-9)
    }

    @Test func theBarIsNeverUnderTheLeastNorOverTwiceIt() {
        #expect(bar(width: 0).height == 48)
        #expect(bar(width: 100).height == 48)
        #expect(bar(width: 800).height == 96)
    }

    @Test func thePictureFillsTheBarLessItsMarginsInItsShape() {
        let tall = bar(width: 800)

        #expect(tall.pictureHeight == 84)
        #expect(abs(tall.pictureWidth / 84 - MiniBarSize.pictureAspect) < 1e-9)
        #expect(bar(width: 0).pictureHeight == 36)
    }
}
