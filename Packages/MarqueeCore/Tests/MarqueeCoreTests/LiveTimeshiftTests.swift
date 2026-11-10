import Testing
@testable import MarqueeCore

struct LiveTimeshiftTests {
    @Test @MainActor func delayedSeekDoesNotUndoPauseOrResumeANewStream() async {
        let intent = LivePlaybackIntent()
        var finishSeek: CheckedContinuation<Void, Never>?
        var playCount = 0
        var seekTask: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            seekTask = intent.seek({
                await withCheckedContinuation { continuation in
                    finishSeek = continuation
                    started.resume()
                }
            }, play: { playCount += 1 })
        }
        intent.pause()
        finishSeek?.resume()
        await seekTask?.value
        #expect(intent.isPaused)
        #expect(playCount == 0)
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            seekTask = intent.seek({
                await withCheckedContinuation { continuation in
                    finishSeek = continuation
                    started.resume()
                }
            }, play: { playCount += 1 })
        }
        intent.reset()
        finishSeek?.resume()
        await seekTask?.value
        #expect(playCount == 0)
        await intent.seek({}, play: { playCount += 1 }).value
        #expect(playCount == 1)
    }

    @Test func liveIsWithinTheToleranceAndAPauseIsAlwaysBehind() {
        #expect(!LiveTimeshift(behindLive: 2.9, reach: 60).isBehindLive)
        #expect(LiveTimeshift(behindLive: 3, reach: 60).isBehindLive)
        #expect(LiveTimeshift(isPaused: true, behindLive: 0.5, reach: 60).isBehindLive)
    }

    @Test func skipsStayWithinTheBufferAndSnapToLive() {
        let shift = LiveTimeshift(behindLive: 20, reach: 30)
        #expect(shift.skipped(by: -15) == 30)
        #expect(shift.skipped(by: 15) == 5)
        #expect(LiveTimeshift(behindLive: 16, reach: 30).skipped(by: 15) == 0)
        #expect(!LiveTimeshift(behindLive: 29.5, reach: 30).canSkipBack)
    }

    @Test func aPauseLongerThanTheBufferDoesNotMoveBackFurther() {
        let shift = LiveTimeshift(isPaused: true, behindLive: 40, reach: 30)
        #expect(shift.skipped(by: -15) == 40)
    }

    @Test func hlsTimesCountFromTheLiveEdgeTheirPlayerKeeps() {
        // A 10-minute window whose end the player trails by 6 s at live.
        let seekable = 100.0...700.0
        let atLive = LiveTimeshift.hls(seekable: seekable, position: 694, liveOffset: 6, isPaused: false)
        #expect(atLive == LiveTimeshift(behindLive: 0, reach: 594))
        let back = LiveTimeshift.hls(seekable: seekable, position: 634, liveOffset: 6, isPaused: true)
        #expect(back == LiveTimeshift(isPaused: true, behindLive: 60, reach: 594))
        #expect(LiveTimeshift.hlsPosition(behindLive: 60, seekable: seekable, liveOffset: 6) == 634)
        #expect(LiveTimeshift.hlsPosition(behindLive: 1000, seekable: seekable, liveOffset: 6) == 100)
        #expect(LiveTimeshift.hls(seekable: nil, position: 5, liveOffset: 6, isPaused: false) == LiveTimeshift())
    }
}
