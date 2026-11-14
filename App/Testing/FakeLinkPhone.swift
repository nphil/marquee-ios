#if DEBUG
import Foundation
import MarqueeCore

/// The UI tests' linked phone (`-marquee.uitest.linkPeer`): "Anna’s iPhone", in reach at once. It drives a
/// TV or glasses, where the focus steps through four titles and a tap plays one, plays on its own screen,
/// or shows nothing, and answers a moment later as a real one does: a cue, then its status. Release
/// builds never make one.
@MainActor
final class FakeLinkPhone: LinkWire {
    enum Mode: String {
        case tv, glasses, phone, idle
    }

    static let id = LinkID("f00dfacef00dfacef00dfacef00dface")!
    static let name = "Anna’s iPhone"
    private static let titles = ["Big Buck Bunny", "Sintel", "Tears of Steel", "Caminandes"]

    let id = FakeLinkPhone.id
    private let mode: Mode
    private let deliver: @MainActor (LinkMessage) -> Void
    private var focus = 0
    private var playing: LinkNowPlaying?
    private var volume = 0.5
    /// When the playhead was last set; a playing clock runs on from it.
    private var anchor = Date.now

    init(mode: Mode, deliver: @escaping @MainActor (LinkMessage) -> Void) {
        self.mode = mode
        self.deliver = deliver
        if mode == .phone {
            playing = LinkNowPlaying(
                title: "Sintel", detail: "2010 · Animation", isPlaying: true, position: 61, duration: 888, hasNext: true,
                subtitles: [LinkSubtitle(id: 1, label: "English"), LinkSubtitle(id: 2, label: "Español")]
            )
        }
    }

    /// The other phone's side of a message; each status heard is answered too, which keeps the link alive.
    func send(_ message: LinkMessage) {
        var replies: [LinkMessage] = []
        switch message {
        case .hello:
            replies.append(.hello(name: Self.name))
        case .input(let input):
            if let cue = handle(input) { replies.append(.cue(cue)) }
        case .command(let command):
            apply(command)
        case .status:
            break
        case .join, .welcome, .cue, .unlink:
            return
        }
        replies.append(.status(status))
        Task { [replies, deliver] in
            for reply in replies { deliver(reply) }
        }
    }

    func close() {}

    private var status: LinkStatus {
        var nowPlaying = playing
        nowPlaying?.position = playing?.position(after: Date.now.timeIntervalSince(anchor)) ?? 0
        switch mode {
        case .tv, .glasses:
            return LinkStatus(
                screen: mode == .tv ? .tv : .glasses, focus: Self.titles[focus], focusDetail: "Movie",
                inPlayer: playing != nil, nowPlaying: nowPlaying, volume: volume
            )
        case .phone:
            return LinkStatus(nowPlaying: nowPlaying, volume: volume)
        case .idle:
            return LinkStatus(volume: volume)
        }
    }

    /// Fixes the running clock into the playhead before a change.
    private func settle() {
        playing?.position = playing?.position(after: Date.now.timeIntervalSince(anchor)) ?? 0
        anchor = .now
    }

    private func handle(_ input: LinkInput) -> HapticCue? {
        guard mode == .tv || mode == .glasses else { return nil }
        settle()
        switch input {
        case .move(let move):
            guard move.isHorizontal else { return .edge }
            let step = move == .right ? 1 : -1
            if var current = playing {
                current.position = min(max(0, current.position + Double(step) * 10), current.duration)
                playing = current
                return .focusStep
            }
            guard Self.titles.indices.contains(focus + step) else { return .edge }
            focus += step
            return .focusStep
        case .select:
            if playing != nil {
                playing?.isPlaying.toggle()
                return .playPause
            }
            playing = LinkNowPlaying(title: Self.titles[focus], isPlaying: true, position: 0, duration: 600)
            return .select
        case .back:
            guard playing != nil else { return .edge }
            playing = nil
            return .back
        case .holdBegan, .holdEnded, .slide, .nudge:
            return nil
        }
    }

    private func apply(_ command: LinkCommand) {
        switch command {
        case .volume(let step):
            volume = LinkVolume.stepped(volume, by: step)
            return
        case .setVolume(let level):
            volume = LinkVolume.clamped(level)
            return
        default:
            break
        }
        settle()
        guard var current = playing else { return }
        switch command {
        case .playPause:
            current.isPlaying.toggle()
        case .skip(let seconds):
            current.position = min(max(0, current.position + seconds), current.duration)
        case .next:
            current = LinkNowPlaying(title: "Tears of Steel", detail: "2012 · Science Fiction", isPlaying: true, position: 0, duration: 734)
        case .subtitle(let id):
            current.subtitle = id
        case .volume, .setVolume:
            break
        }
        playing = current
    }
}
#endif
