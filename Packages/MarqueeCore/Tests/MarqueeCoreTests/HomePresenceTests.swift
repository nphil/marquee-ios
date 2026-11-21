import Foundation
import Testing
@testable import MarqueeCore

struct HomePresenceTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func unknownFailureAndProofTransitions() {
        var presence = HomePresence(gracePeriod: 10)
        #expect(presence.verdict == .unknown)
        #expect(presence.verdict(at: start) == .unknown)
        presence.proofFailed(at: start)
        #expect(presence.verdict == .away)
        presence.proofSucceeded(at: start)
        #expect(presence.verdict == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(100)) == .home)
        presence.proofFailed(at: start.addingTimeInterval(100))
        #expect(presence.verdict == .away)
        presence.proofSucceeded(at: start.addingTimeInterval(101))
        #expect(presence.verdict == .home)
    }

    @Test func graceRunsFromLastSuccessAndExpiresAtBoundary() {
        var presence = HomePresence(gracePeriod: 10)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(2))
        #expect(presence.verdict == .home)
        presence.proofFailed(at: start.addingTimeInterval(9))
        #expect(presence.verdict(at: start.addingTimeInterval(9.999)) == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(10)) == .away)
        presence.proofFailed(at: start.addingTimeInterval(11))
        #expect(presence.verdict == .away)
        presence.proofSucceeded(at: start.addingTimeInterval(12))
        presence.proofFailed(at: start.addingTimeInterval(21))
        #expect(presence.verdict == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(22)) == .away)
    }

    @Test func successDuringGraceRestartsIt() {
        var presence = HomePresence(gracePeriod: 10)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(5))
        presence.proofSucceeded(at: start.addingTimeInterval(6))
        #expect(presence.verdict(at: start.addingTimeInterval(10)) == .home)
        presence.proofFailed(at: start.addingTimeInterval(15))
        #expect(presence.verdict == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(16)) == .away)
    }

    @Test func invalidationImmediatelyForgetsProofOnNetworkChange() {
        var presence = HomePresence(gracePeriod: 10)
        presence.invalidate()
        #expect(presence.verdict == .unknown)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(1))
        presence.invalidate()
        #expect(presence.verdict == .unknown)
        #expect(presence.verdict(at: start.addingTimeInterval(2)) == .unknown)
        presence.proofFailed(at: start.addingTimeInterval(2))
        #expect(presence.verdict == .away)
        presence.invalidate()
        #expect(presence.verdict == .unknown)
        presence.proofSucceeded(at: start.addingTimeInterval(3))
        #expect(presence.verdict == .home)
    }

    @Test func zeroGraceAndClockMovingBackwardsFailClosed() {
        var immediate = HomePresence(gracePeriod: 0)
        immediate.proofSucceeded(at: start)
        immediate.proofFailed(at: start)
        #expect(immediate.verdict == .away)

        var presence = HomePresence(gracePeriod: 10)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(-1))
        #expect(presence.verdict == .away)
        #expect(presence.verdict(at: start.addingTimeInterval(1)) == .away)
    }
}
