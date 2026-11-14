import Foundation

/// The 22 bytes a link connection opens with, in the clear, which are also its handshake's prologue:
/// "MQLK", the version, the mode, and the calling phone's id so the answering phone can pick the key.
public struct LinkPreamble: Sendable, Equatable {
    public enum Mode: UInt8, Sendable {
        case session = 1
        case pairing = 2
    }

    public static let magic = Data("MQLK".utf8)
    public static let version: UInt8 = 1
    public static let length = 22

    public let mode: Mode
    public let caller: LinkID

    public init(mode: Mode, caller: LinkID) {
        self.mode = mode
        self.caller = caller
    }

    /// Nil for bytes that are not a version 1 link preamble.
    public init?(bytes: Data) {
        guard bytes.count == Self.length, bytes.prefix(4) == Self.magic, bytes[bytes.startIndex + 4] == Self.version,
              let mode = Mode(rawValue: bytes[bytes.startIndex + 5]),
              let caller = LinkID(bytes: bytes.suffix(LinkID.length)) else { return nil }
        self.init(mode: mode, caller: caller)
    }

    public var bytes: Data {
        Self.magic + Data([Self.version, mode.rawValue]) + caller.bytes
    }
}

/// One phone's half of pairing, sent inside the pairing handshake: who it is and its key share.
public struct LinkIntroduction: Sendable, Equatable, Codable {
    public let id: LinkID
    public let name: String
    public let share: Data

    public init(id: LinkID, name: String, share: Data) {
        self.id = id
        self.name = name
        self.share = share
    }
}

/// The eyes-free remote's input, as the controlling phone's surface makes it.
public enum LinkInput: Sendable, Equatable {
    case move(FocusMove)
    case select
    case back
    case holdBegan
    case holdEnded
    case slide(dx: Double, width: Double)
    case nudge(seconds: Double)
}

/// The controls for a player on the driving phone's own screen.
public enum LinkCommand: Sendable, Equatable {
    case playPause
    case skip(seconds: Double)
    case next
    /// A subtitle track by its id, or nil for Off.
    case subtitle(Int?)
}

/// The big screen a phone drives.
public enum LinkScreen: String, Sendable, Codable {
    case glasses
    case tv
}

public struct LinkSubtitle: Sendable, Equatable, Codable, Identifiable {
    public let id: Int
    public let label: String

    public init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}

/// What plays on the driving phone, on its big screen or its own.
public struct LinkNowPlaying: Sendable, Equatable, Codable {
    public var title: String
    public var detail: String?
    public var isPlaying: Bool
    /// Seconds into the item when sent, and its length, 0 when not known.
    public var position: Double
    public var duration: Double
    public var hasNext: Bool
    public var subtitles: [LinkSubtitle]
    /// The showing subtitle track, nil for Off.
    public var subtitle: Int?

    public init(
        title: String, detail: String? = nil, isPlaying: Bool, position: Double, duration: Double, hasNext: Bool = false,
        subtitles: [LinkSubtitle] = [], subtitle: Int? = nil
    ) {
        self.title = title
        self.detail = detail
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.hasNext = hasNext
        self.subtitles = subtitles
        self.subtitle = subtitle
    }

    /// The playhead `elapsed` seconds after the status was sent: time runs on while playing, up to the end.
    public func position(after elapsed: TimeInterval) -> Double {
        let moved = position + (isPlaying ? max(0, elapsed) : 0)
        return duration > 0 ? min(moved, duration) : moved
    }
}

/// What a driving phone shows, sent to the phone controlling it whenever it changes.
public struct LinkStatus: Sendable, Equatable, Codable {
    /// The big screen it drives, nil when it drives none.
    public var screen: LinkScreen?
    /// The focused item on the big screen, and its detail line.
    public var focus: String?
    public var focusDetail: String?
    /// The big screen shows the player.
    public var inPlayer: Bool
    public var nowPlaying: LinkNowPlaying?

    public static let maxText = 120
    public static let maxSubtitles = 40

    public init(screen: LinkScreen? = nil, focus: String? = nil, focusDetail: String? = nil, inPlayer: Bool = false, nowPlaying: LinkNowPlaying? = nil) {
        self.screen = screen
        self.focus = focus
        self.focusDetail = focusDetail
        self.inPlayer = inPlayer
        self.nowPlaying = nowPlaying
    }

    /// Whether a controlling phone has anything to drive.
    public var isControllable: Bool { screen != nil || nowPlaying != nil }

    /// Cut to sizes that always fit one frame: texts to 120 characters, at most 40 subtitle tracks.
    public func limited() -> LinkStatus {
        func cut(_ text: String?) -> String? { text.map { String($0.prefix(Self.maxText)) } }
        var status = self
        status.focus = cut(focus)
        status.focusDetail = cut(focusDetail)
        if var playing = nowPlaying {
            playing.title = String(playing.title.prefix(Self.maxText))
            playing.detail = cut(playing.detail)
            playing.subtitles = playing.subtitles.prefix(Self.maxSubtitles).map {
                LinkSubtitle(id: $0.id, label: String($0.label.prefix(Self.maxText)))
            }
            status.nowPlaying = playing
        }
        return status
    }
}

/// A message inside a link session or pairing, one per encrypted frame, as JSON.
public enum LinkMessage: Sendable, Equatable {
    /// Pairing, from the phone that scanned the code.
    case join(LinkIntroduction)
    /// Pairing, the answer of the phone that showed the code.
    case welcome(LinkIntroduction)
    /// The first message of a session, both ways: the sender's current name.
    case hello(name: String)
    case input(LinkInput)
    case command(LinkCommand)
    /// The haptic the driving phone's navigator answered an input with.
    case cue(HapticCue)
    case status(LinkStatus)
    /// The sender unlinked; the receiver forgets it too.
    case unlink

    public func encoded() throws -> Data {
        try JSONEncoder().encode(Wire(self))
    }

    /// Nil for anything this version cannot read, such as a kind of message a newer Marquee sends.
    public static func decode(_ data: Data) -> LinkMessage? {
        (try? JSONDecoder().decode(Wire.self, from: data))?.message
    }
}

/// The JSON form: a `type` and the fields that type uses.
private struct Wire: Codable {
    var type: String
    var intro: LinkIntroduction?
    var name: String?
    var input: String?
    var move: String?
    var dx: Double?
    var width: Double?
    var seconds: Double?
    var command: String?
    var track: Int?
    var cue: String?
    var status: LinkStatus?

    init(type: String) {
        self.type = type
    }

    init(_ message: LinkMessage) {
        switch message {
        case .join(let intro):
            self.init(type: "join")
            self.intro = intro
        case .welcome(let intro):
            self.init(type: "welcome")
            self.intro = intro
        case .hello(let name):
            self.init(type: "hello")
            self.name = name
        case .input(let input):
            self.init(type: "input")
            switch input {
            case .move(let move):
                self.input = "move"
                self.move = move.wireName
            case .select: self.input = "select"
            case .back: self.input = "back"
            case .holdBegan: self.input = "holdBegan"
            case .holdEnded: self.input = "holdEnded"
            case .slide(let dx, let width):
                self.input = "slide"
                self.dx = dx
                self.width = width
            case .nudge(let seconds):
                self.input = "nudge"
                self.seconds = seconds
            }
        case .command(let command):
            self.init(type: "command")
            switch command {
            case .playPause: self.command = "playPause"
            case .skip(let seconds):
                self.command = "skip"
                self.seconds = seconds
            case .next: self.command = "next"
            case .subtitle(let track):
                self.command = "subtitle"
                self.track = track
            }
        case .cue(let cue):
            self.init(type: "cue")
            self.cue = cue.rawValue
        case .status(let status):
            self.init(type: "status")
            self.status = status
        case .unlink:
            self.init(type: "unlink")
        }
    }

    var message: LinkMessage? {
        switch type {
        case "join": intro.map(LinkMessage.join)
        case "welcome": intro.map(LinkMessage.welcome)
        case "hello": name.map { LinkMessage.hello(name: $0) }
        case "input": linkInput.map(LinkMessage.input)
        case "command": linkCommand.map(LinkMessage.command)
        case "cue": cue.flatMap(HapticCue.init(rawValue:)).map(LinkMessage.cue)
        case "status": status.map(LinkMessage.status)
        case "unlink": .unlink
        default: nil
        }
    }

    private var linkInput: LinkInput? {
        switch input {
        case "move": move.flatMap(FocusMove.init(wireName:)).map(LinkInput.move)
        case "select": .select
        case "back": .back
        case "holdBegan": .holdBegan
        case "holdEnded": .holdEnded
        case "slide":
            if let dx, let width, dx.isFinite, width.isFinite { .slide(dx: dx, width: width) } else { nil }
        case "nudge":
            if let seconds, seconds.isFinite { .nudge(seconds: seconds) } else { nil }
        default: nil
        }
    }

    private var linkCommand: LinkCommand? {
        switch command {
        case "playPause": .playPause
        case "skip":
            if let seconds, seconds.isFinite { .skip(seconds: seconds) } else { nil }
        case "next": .next
        case "subtitle": .subtitle(track)
        default: nil
        }
    }
}

extension FocusMove {
    var wireName: String {
        switch self {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
    }

    init?(wireName: String) {
        guard let move = FocusMove.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = move
    }
}

/// When linked phones that find each other call, and which call they keep.
public enum LinkDialing {
    /// The phone with the larger id waits before calling, so the other's call usually arrives first and
    /// only one connection is made.
    public static func delay(me: LinkID, peer: LinkID) -> Duration {
        me < peer ? .zero : .milliseconds(1500)
    }

    /// After failed calls: 2, 4, 8 … seconds, at most a minute.
    public static func retryDelay(failures: Int) -> Duration {
        .seconds(min(60, 1 << min(max(failures, 1), 6)))
    }

    /// Of two connections between the same phones, both keep the one the smaller id called, and the
    /// newer when one phone called both.
    public static func keepsNew(existingCaller: LinkID, newCaller: LinkID) -> Bool {
        newCaller <= existingCaller
    }
}

/// When a phone sends its status: at once when anything but the playhead changed; for the playhead only
/// when it strays a second from where the other phone places it (playing time runs on there); and at
/// least every 5 seconds, which also tells the other phone the link is alive.
public struct LinkStatusPacer: Sendable {
    public static let drift: TimeInterval = 1
    public static let refresh: TimeInterval = 5

    private var sent: LinkStatus?
    private var sentAt: TimeInterval = 0

    public init() {}

    /// `now` is any steadily increasing clock in seconds.
    public mutating func shouldSend(_ status: LinkStatus, now: TimeInterval) -> Bool {
        guard needsSending(status, now: now) else { return false }
        sent = status
        sentAt = now
        return true
    }

    /// The next status goes out whatever it holds, as for a newly connected phone.
    public mutating func reset() {
        sent = nil
    }

    private func needsSending(_ status: LinkStatus, now: TimeInterval) -> Bool {
        guard let sent, now - sentAt < Self.refresh else { return true }
        var current = status
        var previous = sent
        current.nowPlaying?.position = 0
        previous.nowPlaying?.position = 0
        guard current == previous else { return true }
        guard let playing = status.nowPlaying, let before = sent.nowPlaying else { return false }
        return abs(playing.position - before.position(after: now - sentAt)) > Self.drift
    }
}
