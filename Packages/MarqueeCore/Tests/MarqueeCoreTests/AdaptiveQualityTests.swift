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
        #expect(make(.home).ladder == [.original, .mbps8, .mbps4])
        #expect(AdaptiveQuality(place: .home, mediaKbps: nil, linkKbps: nil, now: 0).ladder ==
            [.original, .mbps20, .mbps12, .mbps8, .mbps4])
    }

    @Test func homeStartsAtOriginalUnlessTheMeasuredLinkCannotFitIt() {
        #expect(make(.home).rung == .original)
        #expect(make(.home, link: 3_000).rung == .mbps4)
        #expect(make(.home, link: 3_000).belowFloor)
        // 70% of 14 Mbit/s is 9.8, short of the file's 10.
        #expect(make(.unknown, link: 14_000).rung == .mbps8)
        #expect(make(.away(.tunnel)).rung == .mbps4)
    }

    @Test func aFallingLinkMovesDownOnceTheBufferRunsLow() {
        var abr = make(.unknown, link: 30_000)
        #expect(abr.rung == .original)
        #expect(play(&abr, from: 0, to: 60, kbps: 30_000) { _ in 30 }.isEmpty)
        // 5 Mbit/s drains a 10 Mbit/s buffer at half a second a second; it is under 12 s at 98 s.
        let moves = play(&abr, from: 62, to: 120, kbps: 5_000) { 30 - ($0 - 60) / 2 }
        #expect(moves == [Move(at: 98, to: .mbps4)])
        #expect(abr.belowFloor)
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
        var abr = make(.unknown, link: 3_000)
        #expect(abr.rung == .mbps4)
        #expect(play(&abr, from: 0, to: 60, kbps: 30_000) { _ in 20 } == [Move(at: 20, to: .original)])
    }

    @Test func anEstimateBetweenTheRateAndItsMarginChangesNothing() {
        var abr = make(.unknown)
        #expect(abr.rung == .mbps4)
        // 5 Mbit/s keeps up with the rung's 4 and is far from the 11.4 a climb to 8 needs (8 / 0.7).
        #expect(play(&abr, from: 0, to: 600, kbps: 5_000) { $0 < 300 ? 8 : 30 }.isEmpty)
    }

    @Test func repeatedDropsHoldTheFloorUntilTheLinkRecovers() {
        var abr = make(.unknown, link: 3_000)
        var moves: [Move] = []
        for cycle in 0..<5 {
            let start = TimeInterval(cycle * 60)
            moves += play(&abr, from: start, to: start + 28, kbps: 30_000) { _ in 20 }
            moves += play(&abr, from: start + 30, to: start + 58, kbps: 3_000) { _ in 8 }
        }
        let climbs = moves.filter { $0.to == .original }
        #expect(climbs.count == 2)
        #expect(climbs.allSatisfy { $0.at < 120 })
        #expect(abr.rung == abr.floor)
        let recovered = play(&abr, from: 420, to: 480, kbps: 30_000) { _ in 20 }
        #expect(recovered.map(\.to) == [.original])
        #expect(abr.rung == .original)
    }

    @Test func scoresStopTheClimbWhereMoreRateLooksNoBetter() {
        let scores = QualityScores([.original: 96, .mbps8: 95, .mbps4: 92, .mbps2: 85])
        var abr = make(.unknown, link: 50_000, scores: scores)
        #expect(abr.rung == .mbps8)
        #expect(play(&abr, from: 0, to: 120, kbps: 50_000) { _ in 30 }.isEmpty)
    }

    @Test func largeViewKeepsHDWhileSmallViewUses720p() {
        let source = AdaptiveQuality.Picture(width: 3840, height: 2160)
        let large = AdaptiveQuality(place: .unknown, mediaKbps: 40_000, linkKbps: 1_000,
            source: source, view: .init(width: 1920, height: 1080), now: 0)
        let small = AdaptiveQuality(place: .unknown, mediaKbps: 40_000, linkKbps: 1_000,
            source: source, view: .init(width: 390, height: 844), now: 0)
        #expect(large.floor == .mbps8)
        #expect(large.rung == .mbps8)
        #expect(small.floor == .mbps4)
        #expect(small.rung == .mbps4)
        #expect(large.belowFloor && small.belowFloor)
    }

    @Test func smallOrLowRateOriginalNeverNeedsAnUpscale() {
        for source in [AdaptiveQuality.Picture(width: 426, height: 240), .init(width: 720, height: 480)] {
            let abr = AdaptiveQuality(place: .unknown, mediaKbps: 10_000, linkKbps: 500,
                source: source, view: .init(width: 1920, height: 1080), now: 0)
            #expect(abr.ladder == [.original])
            #expect(abr.rung == .original)
            #expect(abr.belowFloor)
        }
        let lowRate = AdaptiveQuality(place: .unknown, mediaKbps: 2_000, linkKbps: nil, now: 0)
        #expect(lowRate.ladder == [.original])
        #expect(lowRate.rung == .original)
        let hd = AdaptiveQuality(place: .unknown, mediaKbps: 10_000, linkKbps: nil,
            source: .init(width: 1280, height: 720), view: .init(width: 1920, height: 1080), now: 0)
        #expect(hd.floor == .mbps4)
    }

    @Test func atTheFloorWaitingWarnsWithoutAnotherQualityMove() {
        var abr = make(.unknown)
        #expect(abr.observe(.init(now: 2, bufferSeconds: 0, waitingSeconds: 2)) == nil)
        #expect(abr.belowFloor)
        #expect(abr.rung == .mbps4)
        #expect(abr.observe(.init(now: 4, throughputKbps: 10_000, transferSeconds: 2, bufferSeconds: 8)) == nil)
        #expect(!abr.belowFloor)
        // The 10 Mbit/s estimate fits the floor, but it is from before this wait.
        #expect(abr.observe(.init(now: 6, bufferSeconds: 0, waitingSeconds: 2)) == nil)
        #expect(abr.belowFloor)
    }

    @Test func anotherStreamsTelemetryCannotChangeThePolicy() {
        let oldID = UUID()
        var abr = make(.home)
        #expect(abr.observe(.init(now: 2, throughputKbps: 500, transferSeconds: 2,
            bufferSeconds: 0, waitingSeconds: 4, streamID: oldID)) == nil)
        #expect(abr.estimateKbps == nil)
        #expect(abr.rung == .original)
        #expect(!abr.belowFloor)
        #expect(abr.observe(.init(now: 4, throughputKbps: 500, transferSeconds: 2,
            bufferSeconds: 0, streamID: abr.streamID)) == .mbps4)
        #expect(abr.belowFloor)
    }

    @Test func replacingPolicyDropsPreviousLinkHistory() {
        var abr = make(.home)
        _ = abr.observe(.init(now: 2, throughputKbps: 50_000, transferSeconds: 2, bufferSeconds: 30))
        let previous = abr.streamID
        abr = make(.away(.tunnel))
        #expect(abr.streamID != previous)
        #expect(abr.estimateKbps == nil)
        #expect(abr.rung == .mbps4)
        #expect(abr.observe(.init(now: 4, throughputKbps: 50_000, transferSeconds: 2,
            bufferSeconds: 30, streamID: previous)) == nil)
        #expect(abr.estimateKbps == nil)
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
