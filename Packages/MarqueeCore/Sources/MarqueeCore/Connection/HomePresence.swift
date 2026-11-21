import Foundation

/// Presence established by an independent proof, rather than connection characteristics.
public struct HomePresence: Sendable {
    public enum Verdict: Sendable, Equatable {
        case unknown, home, away
    }

    public private(set) var verdict: Verdict = .unknown
    private let gracePeriod: TimeInterval
    private var lastProof: Date?
    private var failed = false

    public init(gracePeriod: TimeInterval) {
        precondition(gracePeriod.isFinite && gracePeriod >= 0)
        self.gracePeriod = gracePeriod
    }

    /// Records a successful home proof at the supplied time.
    public mutating func proofSucceeded(at time: Date) {
        lastProof = time
        failed = false
        verdict = .home
    }

    /// A failure retains home only until the grace period from the last successful proof expires.
    public mutating func proofFailed(at time: Date) {
        failed = true
        _ = verdict(at: time)
    }

    /// Re-evaluates the grace period after a failed proof.
    @discardableResult
    public mutating func verdict(at time: Date) -> Verdict {
        if failed {
            if let lastProof {
                let elapsed = time.timeIntervalSince(lastProof)
                if elapsed < 0 || elapsed >= gracePeriod { verdict = .away }
            } else {
                verdict = .away
            }
        }
        return verdict
    }

    /// Discards proof from the previous network immediately.
    public mutating func invalidate() {
        lastProof = nil
        failed = false
        verdict = .unknown
    }
}
