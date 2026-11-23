import Foundation
import LiveFixtures
import Testing
@testable import LiveEngine

/// LumaTuner's shape: its slate at a fallback size, then the station at its own size, interlaced.
private let tuned: [SyntheticTS.Segment] = [.slate(seconds: 1.5), .station(seconds: 5)]

struct LiveCoreTests {
    @Test func pauseAndResumeReachTheStreamBeingReplaced() {
        let clock = TestClock()
        let buffer = TimeshiftBuffer(folder: nil, limits: .inMemory, segmentBytes: nil) { clock.now }
        buffer.write(Data(repeating: 0, count: 188))
        let feed = LiveFeed(buffer: buffer)
        let output = RecordingOutput { clock.now }
        let previous = LivePipeline(feed: feed, output: output) { _ in }
        let replacement = LivePipeline(feed: feed, output: output, replacing: previous) { _ in }

        replacement.setPaused(true)
        clock.now = 5
        #expect(previous.behindLive == 5)
        replacement.setPaused(false)
        clock.now = 8
        #expect(previous.behindLive == 5)
        replacement.stop()
    }
    @Test func endedInputPlaysBufferedPicturesBeforeDraining() throws {
        let segments: [SyntheticTS.Segment] = [.slate(seconds: 0.5), .station(seconds: 2)]
        let playing = try Simulation.run(segments, tail: 0.5, delivery: { _ in 0 }, finishInput: true)
        #expect(playing.phases.contains(.playing))
        #expect(!playing.core.inputDrained)

        let drained = try Simulation.run(segments, tail: 4, delivery: { _ in 0 }, finishInput: true)
        #expect(drained.phases.contains(.playing))
        #expect(drained.core.inputDrained)
        #expect(drained.count { $0 == .underrun } == 0)
    }

    @Test func emptyEndedInputDrainsUnlessPaused() {
        let clock = TestClock()
        let core = LiveCore(output: RecordingOutput { clock.now }, options: VideoOptions(), startedAt: 0) { _ in }
        core.setPaused(true, now: 0)
        core.finishInput()
        #expect(!core.inputDrained)
        core.setPaused(false, now: 0)
        #expect(core.inputDrained)
    }


    @Test func slateThenStationStartsMotionAndSoundTogether() throws {
        let sim = try Simulation.run(tuned, tail: 0)
        #expect(sim.phases == [.slate, .picture, .playing])
        #expect(sim.events.compactMap { if case .shape(let shape) = $0.event { shape } else { nil } } == ["320×240p", "352×240i"])
        let station = try #require(sim.times(of: .picture).first)
        let splice = try #require(sim.splices.first)
        // The station's first picture goes up as soon as it is decoded: within a frame of its delivery.
        #expect(station - splice < 0.9)
        let playing = try #require(sim.times(of: .playing).first)
        let firstSound = try #require(sim.output.sound.first { $0.time >= 10 + 1.5 })
        #expect(firstSound.at <= playing)
        let timings = sim.core.snapshot.timings
        #expect(timings.slate != nil && timings.picture != nil && timings.sound != nil)
        let format = try #require(timings.format)
        let decoded = try #require(timings.decoded)
        #expect(try format <= decoded && decoded <= #require(timings.slate))
        #expect(sim.count { $0 == .underrun } == 0)
        #expect(sim.core.snapshot.drops == 0)
    }

    @Test func stationSoundArrivingAfterItsFirstPictureStartsOnTheNextIntraPicture() throws {
        // An SD station's pictures run 1.1 s ahead of their arrival, its sound 0.25 s: the sound after the splice
        // comes in behind the first picture, which until then is taken for the slate's.
        let station = SyntheticTS.Segment.station(
            width: 720, height: 480, seconds: 6, bitRate: 1_300_000, soundLeadIn: 0.3, videoLeadSeconds: 1.1,
            soundFramesBeforePicture: 0
        )
        let sim = try Simulation.run([.slate(width: 720, height: 480, seconds: 1.5), station], tail: 0)
        #expect(sim.phases == [.slate, .picture, .playing])
        #expect(sim.count { $0 == .underrun } == 0)
        #expect(sim.count { $0 == .reanchor } == 0)
        #expect(sim.core.snapshot.drops == 0)
    }

    @Test func pictureBeforeSoundIsCalledTheSlateUntilSoundComes() throws {
        let sim = try Simulation.run([.station(seconds: 3)], tail: 0)
        #expect(sim.phases == [.slate, .picture, .playing])
        let timings = sim.core.snapshot.timings
        #expect(timings.slate == nil)
        #expect(timings.picture != nil)
    }

    @Test func underrunStallsThenRaisesTheJitterTarget() throws {
        // Nothing arrives for a second, 3 s in, then the stream carries on a second late.
        let sim = try Simulation.run(tuned, tail: 0, delivery: { $0 < 3 ? $0 : $0 + 1 })
        #expect(sim.count { $0 == .underrun } == 1)
        #expect(Array(sim.phases.suffix(2)) == [.stalled, .playing])
        #expect(abs(sim.core.snapshot.jitterTarget - 0.45) < 1e-9)
        let stall = try #require(sim.core.snapshot.stall)
        #expect(stall.began.audioAhead.map { $0 < 0.05 } == true)
        #expect(stall.resumed?.audioAhead.map { $0 >= 0.45 } == true)
        #expect(stall.audioPackets > 0 && stall.audioPackets == stall.audioDecoded + stall.audioRejected)
        #expect(stall.videoPackets > 0)
    }

    @Test func aClockStartedAheadOfTheAnchorIsSetBackInsteadOfStalling() throws {
        // The channel before left the clock 5.5 s on; the start lands there.
        let sim = try Simulation.run(tuned, tail: 0, clockStartsAhead: 5.5)
        let resets = sim.events.compactMap { entry -> Double? in
            if case .clockReset(let ahead) = entry.event { return ahead }
            return nil
        }
        #expect(resets.count == 1 && abs(resets[0] - 5.5) < 0.2)
        #expect(sim.count { $0 == .underrun || $0 == .reanchor } == 0)
        #expect(sim.phases.last == .playing)
    }

    @Test func pauseHoldsTheClockAndPlaysOnFromTheSamePicture() throws {
        // Paused 4 s in for 2 s; the reader holds the stream back as long.
        var pause: (from: Double, to: Double, rate: Double?) = (0, 0, nil)
        let sim = try Simulation.run(tuned, tail: 0, delivery: { $0 < 4 ? $0 : $0 + 2 }, at: [
            (4, { core, now in
                core.setPaused(true, now: now)
                pause.from = now
            }),
            (5, { core, _ in pause.rate = core.snapshot.rate }),
            (6, { core, now in
                core.setPaused(false, now: now)
                pause.to = now
            }),
        ])
        #expect(pause.rate == 0)
        #expect(!sim.output.pictures.contains { $0.at > pause.from && $0.at < pause.to })
        #expect(sim.count { $0 == .underrun || $0 == .reanchor } == 0)
        #expect(sim.phases.last == .playing)
        #expect(sim.core.snapshot.drops == 0)
    }

    @Test func lateBurstDropsToTheNewestPicture() throws {
        // Three seconds held back and then delivered at once leave the clock far behind live.
        let sim = try Simulation.run(tuned, tail: 0, delivery: { $0 < 2.5 || $0 >= 5.5 ? $0 : 5.5 })
        #expect(sim.count { $0 == .reanchor } == 1)
        #expect(sim.phases.last == .playing)
        #expect((sim.core.snapshot.buffered ?? 0) < 1)
    }

    @Test func tunerRunningFastIsSteeredWithRate() throws {
        let sim = try Simulation.run(tuned, tail: 0, delivery: { $0 * 0.9 })
        #expect(sim.count { if case .servo(let rate) = $0 { rate > 1 } else { false } } > 0)
        #expect(sim.count { $0 == .reanchor || $0 == .underrun } == 0)
    }

    @Test func timelineJumpRestartsFromTheNextIntraPicture() throws {
        let sim = try Simulation.run([.station(seconds: 2), .station(seconds: 2, jump: 100)], tail: 0)
        #expect(sim.count { $0 == .reanchor } == 1)
        #expect(sim.phases.last == .playing)
        #expect(sim.output.pictures.contains { $0.time > 110 })
    }
}
