import Testing
@testable import MarqueeCore

struct ChapterMarksTests {
    private func chapters(_ list: [(String?, Int)]) throws -> [PlexChapter] {
        try list.map { title, start in
            var object: [String: Any] = ["startTimeOffset": start, "endTimeOffset": start + 1]
            if let title { object["tag"] = title }
            return try decode(PlexChapter.self, object)
        }
    }

    @Test func cutsSitAtEachStartExceptTheFirst() throws {
        let marks = ChapterMarks(try chapters([("A", 0), ("B", 250_000), ("C", 500_000)]), duration: 1000)
        #expect(marks.cutFractions == [0.25, 0.5])
    }

    @Test func fewerThanTwoChaptersShowNothing() throws {
        let one = ChapterMarks(try chapters([("A", 0)]), duration: 1000)
        #expect(!one.isShown && one.cutFractions.isEmpty && one.name(at: 10) == nil)
        #expect(!ChapterMarks([], duration: 1000).isShown)
        // Two chapters at one start are one chapter.
        #expect(!ChapterMarks(try chapters([("A", 0), ("B", 0)]), duration: 1000).isShown)
    }

    @Test func cutsAtTheEndsOrCloseTogetherAreLeftOut() throws {
        let marks = ChapterMarks(
            try chapters([("A", 0), ("B", 100_000), ("C", 100_300), ("D", 400_000), ("E", 999_800)]), duration: 1000
        )
        #expect(marks.cutFractions == [0.1, 0.4])
    }

    @Test func theNameIsThatOfTheChapterUnderTheTime() throws {
        // Out of order, as a file may list them.
        let marks = ChapterMarks(try chapters([("B", 100_000), ("A", 0)]), duration: 1000)
        #expect(marks.name(at: 0) == "A")
        #expect(marks.name(at: 99.9) == "A")
        #expect(marks.name(at: 100) == "B")
        #expect(marks.name(at: 5000) == "B")
    }

    @Test func aBlankTitleBecomesChapterNumber() throws {
        let marks = ChapterMarks(try chapters([(nil, 0), ("  ", 100_000), ("Finale", 200_000)]), duration: 1000)
        #expect(marks.name(at: 1) == "Chapter 1")
        #expect(marks.name(at: 150) == "Chapter 2")
        #expect(marks.name(at: 250) == "Finale")
    }

    @Test func aStartIsCrossedOnceInEitherDirection() throws {
        let marks = ChapterMarks(try chapters([("A", 0), ("B", 100_000)]), duration: 1000)
        #expect(marks.crossesStart(from: 99, to: 101))
        #expect(marks.crossesStart(from: 101, to: 99))
        #expect(!marks.crossesStart(from: 101, to: 150))
        #expect(!marks.crossesStart(from: 10, to: 20))
        #expect(!ChapterMarks([], duration: 1000).crossesStart(from: 0, to: 900))
    }
}
