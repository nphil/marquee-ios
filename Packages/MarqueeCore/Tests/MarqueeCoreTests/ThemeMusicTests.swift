import Foundation
import Testing
@testable import MarqueeCore

struct ThemeMusicTests {
    @Test func aShowPlaysItsThemeAndASeasonItsShows() throws {
        func item(_ type: String, _ fields: [String: String]) throws -> PlexMetadata {
            try decode(PlexMetadata.self, fields.merging(["ratingKey": "1", "type": type]) { $1 })
        }
        let tune = "/library/metadata/1/theme/1700000000"

        #expect(ThemeMusic.key(for: try item("show", ["theme": tune])) == tune)
        #expect(ThemeMusic.key(for: try item("season", ["parentTheme": tune, "theme": "/other"])) == tune)
        #expect(ThemeMusic.key(for: try item("show", ["theme": ""])) == nil)
        #expect(ThemeMusic.key(for: try item("episode", ["grandparentTheme": tune])) == nil)
        #expect(ThemeMusic.key(for: try item("movie", ["theme": tune])) == nil)
    }

    @Test func eachConditionHoldsIt() {
        #expect(ThemeMusic.plays(.init()))
        let holds: [ThemeMusic.Conditions] = [
            .init(enabled: false), .init(appActive: false), .init(pageVisible: false), .init(playerOpen: true),
            .init(otherAudioPlaying: true), .init(trailerSounding: true),
        ]
        for conditions in holds {
            #expect(!ThemeMusic.plays(conditions))
        }
    }

    @Test func fadesAtItsPaceAndReversesWithoutAJump() {
        var fade = ThemeFade()
        #expect(fade.isSettled)
        fade.rising = true
        fade.advance(by: 0.75)
        #expect(fade.gain == 0.5)
        #expect(fade.volume(level: 1) == 0.25)
        fade.rising = false
        fade.advance(by: 0.25)
        #expect(fade.gain == 0.25)
        fade.rising = true
        fade.advance(by: 5)
        #expect(fade.gain == 1 && fade.isSettled)
        #expect(fade.volume(level: 0.5) == 0.5)
        fade.rising = false
        fade.advance(by: 1)
        #expect(fade.gain == 0 && fade.isSettled)
    }
}
