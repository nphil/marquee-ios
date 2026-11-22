import Foundation
import Testing
@testable import MarqueeCore

struct ScrubPreviewTests {
    @Test func slotsRoundToTheNearestTenSecondsAndStayInTheTitle() {
        #expect(ScrubPreviewPlan.slotCount(duration: 95) == 10)
        #expect(ScrubPreviewPlan.slot(at: 14, duration: 95) == 1)
        #expect(ScrubPreviewPlan.slot(at: 16, duration: 95) == 2)
        #expect(ScrubPreviewPlan.slot(at: 500, duration: 95) == 9)
        #expect(ScrubPreviewPlan.slot(at: -3, duration: 95) == 0)
        #expect(ScrubPreviewPlan.time(of: 9, duration: 90.5) == 89.5)
    }

    @Test func fillWorksOutwardFromThePlayhead() {
        #expect(ScrubPreviewPlan.fillOrder(playhead: 31, duration: 55) == [3, 4, 2, 5, 1, 0])
        #expect(ScrubPreviewPlan.fillOrder(playhead: 0, duration: 25) == [0, 1, 2])
        #expect(ScrubPreviewPlan.fillOrder(playhead: 0, duration: 0).isEmpty)
    }

    @Test func fillRunsOnlyWhenPlayingAndNothingHoldsItBack() {
        let wifi = ScrubPreviewFillPolicy(isUnmeteredWiFi: true, isPlaying: true)
        #expect(wifi.allows)
        #expect(!ScrubPreviewFillPolicy(isPlaying: true).allows)
        #expect(!ScrubPreviewFillPolicy(isUnmeteredWiFi: true, saveData: true, isPlaying: true).allows)
        #expect(!ScrubPreviewFillPolicy(isUnmeteredWiFi: true, isPlaying: true, isStalled: true).allows)
        #expect(!ScrubPreviewFillPolicy(isUnmeteredWiFi: true, isPlaying: true, isThermalSerious: true).allows)
        #expect(!ScrubPreviewFillPolicy(isUnmeteredWiFi: true).allows)
        #expect(ScrubPreviewFillPolicy(isLocalFile: true, isPlaying: true).allows)
    }

    @Test func pacerStartsAtOnceThenWaitsOutTheQuietTime() {
        var pacer = ScrubPreviewPacer()
        let start = ContinuousClock.now
        #expect(pacer.delay(at: start) == .zero)
        #expect(pacer.delay(at: start.advanced(by: .milliseconds(30))) == .milliseconds(50))
        // The held frame starts at 80 ms, so the next waits from there.
        #expect(pacer.delay(at: start.advanced(by: .milliseconds(100))) == .milliseconds(60))
        #expect(pacer.delay(at: start.advanced(by: .milliseconds(400))) == .zero)
        pacer.reset()
        #expect(pacer.delay(at: start.advanced(by: .milliseconds(401))) == .zero)
    }

    @Test func diskEvictsTheOldestFramesPastTheCap() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scrub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ScrubPreviewDisk(directory: directory, cap: 25)
        let frame = Data(repeating: 1, count: 10)
        await disk.store(frame, part: 7, slot: 0)
        await disk.store(frame, part: 7, slot: 1)
        await disk.store(frame, part: 8, slot: 0)
        #expect(await disk.data(part: 7, slot: 0) == nil)
        #expect(await disk.slots(part: 7) == [1])
        #expect(await disk.data(part: 8, slot: 0) == frame)
        #expect(await disk.byteCount == 20)
    }

    @Test func diskKeepsWhatAnEarlierRunLeftInItsOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scrub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ScrubPreviewDisk(directory: directory, cap: 25)
        let frame = Data(repeating: 1, count: 10)
        await first.store(frame, part: 1, slot: 0)
        await first.store(frame, part: 1, slot: 1)
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.appending(path: "1/0.jpg").path)

        let again = ScrubPreviewDisk(directory: directory, cap: 25)
        #expect(await again.slots(part: 1) == [0, 1])
        await again.store(frame, part: 1, slot: 2)
        #expect(await again.slots(part: 1) == [1, 2])
    }
}
