import Foundation
import Testing
@testable import MarqueeCore

struct SubtitleLookTests {
    @Test func changingAFieldMakesTheLookCustomUntilResetToItsPreset() {
        var look = SubtitleLook()
        look.colour = .yellow
        #expect(look.isCustom && look.preset == .blend)
        look.colour = .white
        #expect(!look.isCustom)
        look.apply(.classic)
        look.reveal = .word
        look.keepsFileStyling = false
        #expect(!look.isCustom && look.background == .lineBox)
        look.size = 200
        look.resetToPreset()
        #expect(look.preset == .classic && !look.isCustom && look.size == 100 && look.reveal == .word && !look.keepsFileStyling)
    }

    @Test func storedLooksKeepCustomAndSurviveUnknownValues() throws {
        var custom = SubtitleLook(preset: .netflix)
        custom.edgeWidth = 6
        let decoded = try JSONDecoder().decode(SubtitleLook.self, from: JSONEncoder().encode(custom))
        #expect(decoded == custom && decoded.isCustom)

        let unknown = try JSONDecoder().decode(SubtitleLook.self, from: Data(#"{"preset":"neon","font":"comic","size":130}"#.utf8))
        #expect(unknown.preset == .blend && unknown.font == .standard && unknown.size == 130)

        let old = Data(#"{"size":"large","colour":"yellow","edge":"shadow","isBold":false}"#.utf8)
        #expect(try JSONDecoder().decode(SubtitleLook.self, from: old) == SubtitleLook())
    }

    @Test func wordsAppearInOrderWithPausesAndATail() {
        let words = SubtitleReveal.estimate("Run, now.\nWhere?", duration: 3, by: .word)
        #expect(words.map(\.offset) == [0, 5, 10])
        #expect(words.map(\.length) == [4, 4, 6])
        #expect(words[0].start == 0 && words[1].start > words[0].start && words[2].start > words[1].start)
        #expect(words[2].start < 2.7)
        #expect(abs(SubtitleReveal.visibility(of: words[1], at: words[1].start + SubtitleReveal.fade / 2) - 0.5) < 1e-9)
    }

    @Test func linesAppearWholeAndOffMeansNoReveal() {
        let lines = SubtitleReveal.estimate("One two\nthree", duration: 2, by: .line)
        #expect(lines[0].start == lines[1].start && lines[2].start > lines[1].start)
        #expect(SubtitleReveal.estimate("One two", duration: 2, by: .off).isEmpty)
        #expect(SubtitleReveal.estimate("東京へ", duration: 1, by: .word).count == 3)
    }
}
