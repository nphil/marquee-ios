import Foundation
import Testing
@testable import MarqueeCore

struct RemuxHandOffTests {
    /// Landing 4 s past the run's start needs 36 s remuxed.
    let gate = RemuxHandOff(landing: 104)

    func decide(origin: TimeInterval?, media: TimeInterval, paced: Bool = false, finished: Bool = false, ms: Int = 200) -> RemuxHandOff.Decision {
        gate.decide(origin: origin, mediaSeconds: media, isPaced: paced, finished: finished, elapsed: .milliseconds(ms))
    }

    @Test func waitsForTheLeadPastTheLandingPoint() {
        #expect(decide(origin: nil, media: 0) == .wait(nil))
        #expect(decide(origin: 100, media: 9) == .wait(0.25))
        #expect(decide(origin: 100, media: 36) == .handOver(.lead))
    }

    @Test func aSlowSourceHandsOverAtTheCap() {
        #expect(decide(origin: 100, media: 9, ms: 1499) == .wait(0.25))
        #expect(decide(origin: 100, media: 9, ms: 1500) == .handOver(.cap))
        #expect(decide(origin: nil, media: 0, ms: 1500) == .handOver(.cap))
    }

    @Test func aPacedOrFinishedRemuxHandsOverAtOnce() {
        #expect(decide(origin: 100, media: 9, paced: true) == .handOver(.paced))
        #expect(decide(origin: nil, media: 0, finished: true) == .handOver(.end))
    }
}
