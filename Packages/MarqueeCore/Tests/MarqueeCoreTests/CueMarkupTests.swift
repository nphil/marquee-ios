import Foundation
import Testing
@testable import MarqueeCore

/// `{\anN}` at the start of an SRT cue, as in the signs and songs merged into a full track: the cue goes
/// where the tag says and the tag is never shown.
struct CueMarkupTests {
    /// A cue's text through the file preparation and back out of the reader.
    private func placed(_ cue: String) -> (text: String, alignment: CueAlignment?) {
        CueMarkup.placing(String(decoding: CueMarkup.marking(Data(cue.utf8)), as: UTF8.self))
    }

    @Test func aTopTagPlacesTheCueAtTheTopAndLeavesNoText() {
        let cue = placed("{\\an8}Tokyo Tower")

        #expect(cue.text == "Tokyo Tower")
        #expect(cue.alignment == CueAlignment(number: 8))
        #expect(cue.alignment?.vertical == .top && cue.alignment?.horizontal == .centre)
    }

    @Test func onlyTheFirstTagPlacesTheCueAndNoTagShows() {
        let cue = placed("<i>{\\an7}Top left</i>\n{\\an2}and below")

        #expect(cue.text == "<i>Top left</i>\nand below")
        #expect(cue.alignment == CueAlignment(number: 7))
    }

    @Test(arguments: [
        (1, CueAlignment.Vertical.bottom, CueAlignment.Horizontal.left), (2, .bottom, .centre), (3, .bottom, .right),
        (4, .middle, .left), (5, .middle, .centre), (6, .middle, .right),
        (7, .top, .left), (8, .top, .centre), (9, .top, .right),
    ])
    func everyNumberNamesAPlace(number: Int, vertical: CueAlignment.Vertical, horizontal: CueAlignment.Horizontal) {
        let cue = placed("{\\an\(number)}Line")

        #expect(cue.alignment?.vertical == vertical && cue.alignment?.horizontal == horizontal)
        #expect(cue.text == "Line")
    }

    @Test func otherTextIsLeftAsItIs() {
        for text in ["Plain", "{\\i1}Styled{\\i0}", "{\\an0}Zero", "{\\an10}Ten", "{\\an8 Open", "{an8}No slash"] {
            #expect(Data(text.utf8) == CueMarkup.marking(Data(text.utf8)))
            #expect(placed(text).text == text && placed(text).alignment == nil)
        }
    }
}
