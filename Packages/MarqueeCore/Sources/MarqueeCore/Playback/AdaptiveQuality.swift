import Foundation

/// The quality setting: Auto, or one fixed ceiling (docs/adaptive-playback.md).
public enum QualitySetting: Sendable, Hashable {
    case auto
    case fixed(VideoQuality)

    /// Auto, then every fixed quality from Original down.
    public static let all: [QualitySetting] = [.auto] + VideoQuality.allCases.map(QualitySetting.fixed)

    /// What a profile saved before Auto existed becomes: a lowered quality stays, Original (the old default,
    /// which cannot be told apart from an untouched setting) becomes Auto.
    public static func saved(legacy: VideoQuality?) -> QualitySetting {
        guard let legacy, legacy != .original else { return .auto }
        return .fixed(legacy)
    }

    /// "Auto", or the fixed quality's title.
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .fixed(let quality): quality.title
        }
    }
}

extension QualitySetting: Codable {
    /// One integer: -1 for Auto, else the fixed quality's raw value.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        if raw == -1 {
            self = .auto
        } else if let quality = VideoQuality(rawValue: raw) {
            self = .fixed(quality)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No quality \(raw)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode(-1)
        case .fixed(let quality): try container.encode(quality.rawValue)
        }
    }
}

/// A title's picture quality at each rung as VMAF scores (0-100). With scores, Auto climbs no higher than
/// the lowest rung within `enough` points of the best, so a title that looks the same at 8 Mbps does not
/// pull 20. Nothing supplies scores yet.
public struct QualityScores: Sendable, Hashable {
    public var scores: [VideoQuality: Double]
    public static let enough = 1.5

    public init(_ scores: [VideoQuality: Double]) {
        self.scores = scores
    }

    /// The lowest rung of `ladder` (best first) that scores within `enough` of the best; nil without scores.
    func ceiling(in ladder: [VideoQuality]) -> VideoQuality? {
        let scored = ladder.filter { scores[$0] != nil }
        guard let best = scored.compactMap({ scores[$0] }).max() else { return nil }
        return scored.last { scores[$0]! >= best - Self.enough }
    }
}

/// Auto quality's rung while one video plays (docs/adaptive-playback.md). The app shows it a look at the
/// stream every couple of seconds; a returned rung is a move to make, after which `moved(to:at:)` says where
/// playback ended up. No other move comes in between.
public struct AdaptiveQuality: Sendable {
    public struct Tuning: Sendable {
        /// A rung fits the link when its rate is at most this share of the estimate.
        public var fit = 0.7
        /// A wait on the network this long moves down.
        public var stallWait: TimeInterval = 2
        /// Less buffer than this, with the estimate below the rung's rate, moves down.
        public var lowBuffer: TimeInterval = 12
        /// A climb needs this much buffer, the estimate fitting the higher rung for `climbHold`, and `dwell`
        /// since the last move.
        public var climbBuffer: TimeInterval = 10
        public var climbHold: TimeInterval = 10
        public var dwell: TimeInterval = 20
        /// The first drop this soon after a climb doubles the climb's hold, up to `maxClimbHold`; `calm`
        /// without a drop resets it.
        public var flapWindow: TimeInterval = 60
        public var maxClimbHold: TimeInterval = 160
        public var calm: TimeInterval = 300
        public var fastHalfLife: TimeInterval = 3
        public var slowHalfLife: TimeInterval = 10
        /// The start away from home with no measured link.
        public var awayStart = VideoQuality.mbps4

        public init() {}
    }

    /// One look at the stream.
    public struct Look: Sendable {
        public var now: TimeInterval
        /// The link's speed while data moved since the last look, and for how long it moved; nil when none did.
        public var throughputKbps: Int?
        public var transferSeconds: TimeInterval
        /// Media on the phone ahead of the playhead; nil when unknown.
        public var bufferSeconds: TimeInterval?
        /// How long playback has waited on the network; 0 while it plays.
        public var waitingSeconds: TimeInterval

        public init(
            now: TimeInterval, throughputKbps: Int? = nil, transferSeconds: TimeInterval = 0,
            bufferSeconds: TimeInterval? = nil, waitingSeconds: TimeInterval = 0
        ) {
            self.now = now
            self.throughputKbps = throughputKbps
            self.transferSeconds = transferSeconds
            self.bufferSeconds = bufferSeconds
            self.waitingSeconds = waitingSeconds
        }
    }

    /// The rung playing, or being moved to.
    public private(set) var rung: VideoQuality
    /// Original, then every preset below the file's rate; best first.
    public let ladder: [VideoQuality]
    private let mediaKbps: Int?
    /// The highest rung a climb or an away start reaches (`QualityScores`).
    private let ceiling: VideoQuality?
    private let tuning: Tuning
    private var fast: MovingAverage
    private var slow: MovingAverage
    private var moving = false
    private var lastMove: TimeInterval
    private var lastClimb: TimeInterval?
    private var lastDrop: TimeInterval
    private var climbSince: TimeInterval?
    private var climbHold: TimeInterval

    /// - Parameter linkKbps: the link to the server as an earlier stream measured it.
    public init(
        place: NetworkPlace, mediaKbps: Int?, linkKbps: Int?, scores: QualityScores? = nil, tuning: Tuning = Tuning(),
        now: TimeInterval
    ) {
        let ladder = [VideoQuality.original] + VideoQuality.allCases.filter { preset in
            guard let rate = preset.maxBitrateKbps else { return false }
            return mediaKbps.map { rate < $0 } ?? true
        }
        self.ladder = ladder
        self.mediaKbps = mediaKbps
        self.tuning = tuning
        ceiling = scores?.ceiling(in: ladder)
        fast = MovingAverage(halfLife: tuning.fastHalfLife)
        slow = MovingAverage(halfLife: tuning.slowHalfLife)
        lastMove = now
        lastDrop = now
        climbHold = tuning.climbHold
        rung = .original
        guard !place.isHome else { return }
        // Away with no measured link, a low rung starts fast and the climb follows.
        rung = linkKbps.map { fitting(Double($0)) }
            ?? climbable.first { (rate(of: $0) ?? .max) <= tuning.awayStart.rawValue }
            ?? climbable.last!
    }

    /// The link estimate in kbit/s: the lower of a fast and a slow moving average; nil before any data moved.
    public var estimateKbps: Int? {
        guard let fast = fast.value, let slow = slow.value else { return nil }
        return Int(min(fast, slow))
    }

    /// Takes in one look; returns the rung to move to, or nil to stay.
    public mutating func observe(_ look: Look) -> VideoQuality? {
        if let kbps = look.throughputKbps, look.transferSeconds > 0 {
            fast.add(Double(kbps), weight: look.transferSeconds)
            slow.add(Double(kbps), weight: look.transferSeconds)
        }
        guard !moving else { return nil }
        if look.now - lastDrop >= tuning.calm { climbHold = tuning.climbHold }
        let estimate = estimateKbps.map(Double.init)

        let behind = estimate.flatMap { estimate in rate(of: rung).map { estimate < Double($0) } } ?? false
        if look.waitingSeconds >= tuning.stallWait || (behind && (look.bufferSeconds ?? .infinity) < tuning.lowBuffer) {
            guard let lower = step(below: rung) else { return nil }
            // At least one step down; further when the estimate fits only a lower rung.
            let fit = estimate.map { fitting($0, in: ladder) }
            if let lastClimb, look.now - lastClimb <= tuning.flapWindow {
                climbHold = min(climbHold * 2, tuning.maxClimbHold)
                self.lastClimb = nil
            }
            lastDrop = look.now
            return move(to: fit.map { isBetter(lower, than: $0) ? $0 : lower } ?? lower)
        }

        guard let estimate, (look.bufferSeconds ?? 0) >= tuning.climbBuffer, isBetter(fitting(estimate), than: rung) else {
            climbSince = nil
            return nil
        }
        let since = climbSince ?? look.now
        climbSince = since
        guard look.now - since >= climbHold, look.now - lastMove >= tuning.dwell else { return nil }
        lastClimb = look.now
        return move(to: fitting(estimate))
    }

    /// The move is over: playback runs at `rung`, the one asked for or, when the move failed, the one before.
    public mutating func moved(to rung: VideoQuality, at now: TimeInterval) {
        self.rung = rung
        moving = false
        lastMove = now
        climbSince = nil
    }

    private mutating func move(to target: VideoQuality) -> VideoQuality {
        rung = target
        moving = true
        climbSince = nil
        return target
    }

    /// The ladder from the ceiling down.
    private var climbable: [VideoQuality] {
        guard let ceiling, let start = ladder.firstIndex(of: ceiling) else { return ladder }
        return Array(ladder[start...])
    }

    /// The best rung that fits the link, else the lowest.
    private func fitting(_ estimate: Double) -> VideoQuality {
        fitting(estimate, in: climbable)
    }

    private func fitting(_ estimate: Double, in rungs: [VideoQuality]) -> VideoQuality {
        rungs.first { rate(of: $0).map { Double($0) <= estimate * tuning.fit } ?? false } ?? rungs.last!
    }

    /// The rung's rate: the file's for Original, which is unknown when the server did not say.
    private func rate(of rung: VideoQuality) -> Int? {
        rung == .original ? mediaKbps : rung.maxBitrateKbps
    }

    private func step(below rung: VideoQuality) -> VideoQuality? {
        guard let index = ladder.firstIndex(of: rung), index + 1 < ladder.count else { return nil }
        return ladder[index + 1]
    }

    private func isBetter(_ a: VideoQuality, than b: VideoQuality) -> Bool {
        guard let i = ladder.firstIndex(of: a), let j = ladder.firstIndex(of: b) else { return false }
        return i < j
    }
}

/// An exponentially weighted moving average over samples weighted by duration, corrected for its start at
/// zero.
private struct MovingAverage: Sendable {
    let halfLife: TimeInterval
    private var sum = 0.0
    private var weight = 0.0

    init(halfLife: TimeInterval) {
        self.halfLife = halfLife
    }

    mutating func add(_ sample: Double, weight: TimeInterval) {
        let kept = pow(0.5, weight / halfLife)
        sum = sample * (1 - kept) + sum * kept
        self.weight += weight
    }

    var value: Double? {
        weight > 0 ? sum / (1 - pow(0.5, weight / halfLife)) : nil
    }
}
