import Foundation
import LiveEngine
import LiveFixtures
import Testing
@testable import MarqueeLive

@MainActor
struct LiveStreamPlayerTests {
    @Test func eventsOfAReplacedStreamAreDropped() {
        let player = LiveStreamPlayer()
        player.play(TimeshiftBuffer(folder: nil, limits: .inMemory))
        let replaced = player.generation
        player.play(TimeshiftBuffer(folder: nil, limits: .inMemory))
        // The old stream ends as the new one takes over; that must not fail the new one.
        player.handle(.ended, from: replaced)
        player.handle(.engine(.phase(.playing)), from: replaced)
        #expect(player.state == .opening)
        player.handle(.engine(.phase(.slate)), from: player.generation)
        #expect(player.state == .slate)
        player.close()
        #expect(player.state == .idle)
        #expect(player.isStopped)
    }

    @Test func aSeekPlaysOnFromThePictureOnScreenWithoutTuningAgain() {
        let player = LiveStreamPlayer()
        player.play(TimeshiftBuffer(folder: nil, limits: .inMemory))
        player.handle(.engine(.phase(.playing)), from: player.generation)
        player.pause()
        #expect(player.isPaused)
        player.seek(behindLive: 30)
        #expect(!player.isPaused)
        // The new position's opening and first picture stay behind the picture already on screen.
        player.handle(.engine(.phase(.opening)), from: player.generation)
        player.handle(.engine(.phase(.picture)), from: player.generation)
        #expect(player.state == .playing)
        player.handle(.engine(.phase(.stalled)), from: player.generation)
        #expect(player.state == .playing)
        player.handle(.engine(.phase(.playing)), from: player.generation)
        player.handle(.engine(.phase(.stalled)), from: player.generation)
        #expect(player.state == .stalled)
        player.close()
        #expect(player.isStopped)
        #expect(!player.isPaused)
    }

    @Test func recordedStreamPlaysOnTheSampleBufferRenderers() async throws {
        let stream = try SyntheticTS.make([.slate(seconds: 0.5), .station(seconds: 2)])
        let player = LiveStreamPlayer()
        let buffer = TimeshiftBuffer(folder: nil, limits: .inMemory)
        player.play(buffer)
        buffer.write(stream.bytes)
        buffer.finish()
        // Everything is buffered at once, so motion starts as soon as the first pictures decode.
        let deadline = ContinuousClock.now + .seconds(5)
        while player.state != .playing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.state == .playing)
        #expect(player.diagnostics.timings.picture != nil)
        #expect(player.audioTracks.map(\.codec) == ["ac3"])
        player.close()
    }
}
