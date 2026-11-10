import Foundation
import Testing
@testable import MarqueeCore

/// A 10 Mbit/s file, looked at every 2 s on a made-up clock; each move finishes at once.
struct AdaptiveQualityTests {
    static let fileKbps = 10_000

    private func make(_ place: NetworkPlace, link: Int? = nil, scores: QualityScores? = nil) -> AdaptiveQuality {
        AdaptiveQuality(place: place, mediaKbps: Self.fileKbps, linkKbps: link, scores: scores, now: 0)
    }

    /// Looks from `from` to `to` with this link and buffer; returns each move and when it came.
    private func play(
        _ abr: inout AdaptiveQuality, from: TimeInterval, to: TimeInterval, kbps: Int,
        buffer: (TimeInterval) -> TimeInterval
    ) -> [Move] {
        var moves: [Move] = []
        for now in stride(from: from, through: to, by: 2) {
            let look = AdaptiveQuality.Look(now: now, throughputKbps: kbps, transferSeconds: 2, bufferSeconds: buffer(now))
            if let rung = abr.observe(look) {
                moves.append(Move(at: now, to: rung))
                abr.moved(to: rung, at: now)
            }
        }
        return moves
    }

    struct Move: Equatable {
        let at: TimeInterval
        let to: VideoQuality
    }

    @Test func theLadderIsOriginalAndThePresetsBelowTheFile() {
        #expect(make(.home).ladder == [.original, .mbps8, .mbps4, .mbps2])
        #expect(AdaptiveQuality(place: .home, mediaKbps: nil, linkKbps: nil, now: 0).ladder == VideoQuality.allCases)
    }

    @Test func homeStartsAtOriginalAndAwayAtWhatTheLinkFits() {
        #expect(make(.home, link: 3_000).rung == .original)
        // 70% of 14 Mbit/s is 9.8, short of the file's 10.
        #expect(make(.away(.remote), link: 14_000).rung == .mbps8)
        #expect(make(.away(.tunnel)).rung == .mbps4)
    }

    @Test func aFallingLinkMovesDownOnceTheBufferRunsLow() {
        var abr = make(.away(.remote), link: 30_000)
        #expect(abr.rung == .original)
        #expect(play(&abr, from: 0, to: 60, kbps: 30_000) { _ in 30 }.isEmpty)
        // 5 Mbit/s drains a 10 Mbit/s buffer at half a second a second; it is under 12 s at 98 s.
        let moves = play(&abr, from: 62, to: 120, kbps: 5_000) { 30 - ($0 - 60) / 2 }
        #expect(moves == [Move(at: 98, to: .mbps2)])
    }

    @Test func aWaitOnTheNetworkStepsDownOnceUntilTheMoveIsDone() {
        var abr = make(.home)
        _ = play(&abr, from: 0, to: 10, kbps: 50_000) { _ in 30 }
        let waiting = AdaptiveQuality.Look(now: 12, bufferSeconds: 0, waitingSeconds: 2)
        #expect(abr.observe(waiting) == .mbps8)
        #expect(abr.observe(AdaptiveQuality.Look(now: 13, bufferSeconds: 0, waitingSeconds: 3)) == nil)
        abr.moved(to: .mbps8, at: 14)
        #expect(abr.observe(AdaptiveQuality.Look(now: 16, bufferSeconds: 0, waitingSeconds: 2)) == .mbps4)
    }

    @Test func aRecoveredLinkClimbsAfterTheHoldAndTheDwell() {
        var abr = make(.away(.remote), link: 3_000)
        #expect(abr.rung == .mbps2)
        #expect(play(&abr, from: 0, to: 60, kbps: 30_000) { _ in 20 } == [Move(at: 20, to: .original)])
    }

    @Test func anEstimateBetweenTheRateAndItsMarginChangesNothing() {
        var abr = make(.away(.remote))
        #expect(abr.rung == .mbps4)
        // 5 Mbit/s keeps up with the rung's 4 and is far from the 11.4 a climb to 8 needs (8 / 0.7).
        #expect(play(&abr, from: 0, to: 600, kbps: 5_000) { $0 < 300 ? 8 : 30 }.isEmpty)
    }

    @Test func aLinkThatDropsAfterEachClimbStopsClimbingUntilFiveCalmMinutes() {
        var abr = make(.away(.remote), link: 3_000)
        var moves: [Move] = []
        // 30 s at 30 Mbit/s, then 30 s at 3 Mbit/s with the buffer run down, for 5 minutes.
        for cycle in 0..<5 {
            let start = TimeInterval(cycle * 60)
            moves += play(&abr, from: start, to: start + 28, kbps: 30_000) { _ in 20 }
            moves += play(&abr, from: start + 30, to: start + 58, kbps: 3_000) { _ in 8 }
        }
        // The hold doubles with each drop, to 40 s after the second: longer than a good spell.
        #expect(moves.filter { $0.to == .original }.map(\.at) == [20, 80])
        let calm = play(&abr, from: 420, to: 480, kbps: 30_000) { _ in 20 }
        #expect(calm == [Move(at: 430, to: .original)])
    }

    @Test func scoresStopTheClimbWhereMoreRateLooksNoBetter() {
        let scores = QualityScores([.original: 96, .mbps8: 95, .mbps4: 92, .mbps2: 85])
        var abr = make(.away(.remote), link: 50_000, scores: scores)
        #expect(abr.rung == .mbps8)
        #expect(play(&abr, from: 0, to: 120, kbps: 50_000) { _ in 30 }.isEmpty)
    }

    @Test func theSettingSavesAutoAsMinusOneAndKeepsALoweredLegacyQuality() throws {
        let saved = try JSONEncoder().encode([QualitySetting.auto, .fixed(.mbps8)])
        #expect(String(decoding: saved, as: UTF8.self) == "[-1,8000]")
        #expect(try JSONDecoder().decode([QualitySetting].self, from: saved) == [.auto, .fixed(.mbps8)])
        #expect(QualitySetting.saved(legacy: nil) == .auto)
        #expect(QualitySetting.saved(legacy: .original) == .auto)
        #expect(QualitySetting.saved(legacy: .mbps4) == .fixed(.mbps4))
    }
}
