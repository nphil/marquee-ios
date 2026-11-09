import Foundation
import Testing
@testable import MarqueeCore

struct TrailerAutoplayTests {
    @Test func playsWithSoundWhenNothingArguesAgainst() {
        #expect(TrailerAutoplay.decide(.init()) == .play(muted: false))
    }

    @Test func eachConditionHoldsIt() {
        let holds: [TrailerAutoplay.Conditions] = [
            .init(enabled: false), .init(lowPowerMode: true), .init(reduceMotion: true), .init(metered: true),
            .init(appActive: false), .init(heroVisible: false), .init(playerOpen: true),
        ]
        for conditions in holds {
            #expect(TrailerAutoplay.decide(conditions) == .hold)
        }
    }

    @Test func otherAudioMutesItRatherThanHoldingIt() {
        #expect(TrailerAutoplay.decide(.init(otherAudioPlaying: true)) == .play(muted: true))
    }

    @Test func onlyAFilePlayedUntouchedIsPreviewed() throws {
        func trailer(_ container: String, video: String, audio: String = "aac") throws -> PlexMedia {
            try decode(PlexMedia.self, [
                "id": 1, "container": container,
                "Part": [[
                    "id": 7, "key": "/library/parts/7/file.\(container)", "container": container,
                    "Stream": [Fixture.video(video), Fixture.audio(2, "eng", codec: audio, isDefault: true)],
                ]],
            ])
        }
        let device = DeviceCapabilities()

        #expect(TrailerAutoplay.directPart(of: [try trailer("mp4", video: "h264")], capabilities: device)?.id == 7)
        #expect(TrailerAutoplay.directPart(of: [try trailer("mkv", video: "h264")], capabilities: device) == nil)
        #expect(TrailerAutoplay.directPart(of: [try trailer("mp4", video: "h264", audio: "dts")], capabilities: device) == nil)
        let both = [try trailer("mkv", video: "h264"), try trailer("mp4", video: "h264")]
        #expect(TrailerAutoplay.directPart(of: both, capabilities: device)?.id == 7)
        #expect(TrailerAutoplay.directPart(of: [], capabilities: device) == nil)
    }
}
