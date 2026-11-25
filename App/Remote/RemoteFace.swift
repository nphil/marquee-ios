import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import SwiftUI
import UIKit

/// The panel's face: the header, and under it the pad and the strips of keys the layout has room for, or the
/// invitation to pair while no TV is chosen. Arranging draws over the same layout.
struct RemoteFace: View {
    let size: CGSize

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model

    /// How long a finger rests on an empty spot before the panel starts being arranged.
    private static let hold = 0.6

    /// Keys reach the TV only while a session is open and the screen is on; Power works regardless.
    private var ready: Bool { model.connection == .connected && model.state.power == .on }

    var body: some View {
        let remote = session.remote
        let hidden = RemoteModule.allCases.filter { $0 != .pad && !remote.modules.contains($0) }
        let plain = RemoteLayout(width: size.width, height: size.height, visible: remote.modules)
        // The tray costs a strip of height, so it is there only while there is something to put in it.
        let tray = stage.editing && (!hidden.isEmpty || !plain.dropped.isEmpty)
        let layout = tray
            ? RemoteLayout(width: size.width, height: size.height, visible: remote.modules, tray: RemoteMetrics.tray)
            : plain
        ZStack(alignment: .topLeading) {
            // An empty spot: a press and hold here starts arranging.
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: Self.hold) {
                    guard model.current != nil, !stage.editing else { return }
                    model.feedback.click()
                    stage.editing = true
                }
            if model.current == nil {
                NoTV(size: size)
            } else {
                controls(layout)
                    .allowsHitTesting(!stage.editing)
                    .accessibilityHidden(stage.editing)
            }
            if stage.editing {
                RemoteArrange(size: size, layout: layout, hidden: hidden, tray: tray)
            }
            // Last, so it is over everything, and first for VoiceOver.
            Group {
                if stage.editing {
                    RemoteEditHeader(width: size.width)
                } else {
                    RemoteHeader(width: size.width)
                }
            }
            .accessibilitySortPriority(1)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: layout.shape) {
            if stage.editing { model.feedback.tick() }
        }
        .onChange(of: model.current == nil) { _, none in
            if none { stage.editing = false }
        }
    }

    private func controls(_ layout: RemoteLayout) -> some View {
        let remote = session.remote
        return ZStack(alignment: .topLeading) {
            PadRegion(mode: remote.mode, ready: ready, onMode: remote.setMode)
                .placed(layout.pad)
            ForEach(layout.strips, id: \.strip) { placement in
                StripKeys(placement: placement, ready: ready)
            }
        }
    }
}

// MARK: Keys

/// One strip's keys, at the rectangles the layout gave them.
private struct StripKeys: View {
    let placement: StripPlacement
    let ready: Bool

    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let rects = placement.keyRects
        switch placement.strip {
        case .nav:
            Group {
                keyButton(.back, "arrow.uturn.backward", "TV Back").placed(rects[0])
                keyButton(.home, "house", "TV Home").placed(rects[1])
                keyButton(.menu, "gearshape", "TV Settings").placed(rects[2])
            }
            .disabled(!ready)
        case .volume:
            volumeKeys(rects)
                .disabled(!ready)
        case .channel:
            Group {
                keyButton(.channelDown, "chevron.down", "Channel down").placed(rects[0])
                keyButton(.guide, "tablecells", "Guide").placed(rects[1])
                keyButton(.channelUp, "chevron.up", "Channel up").placed(rects[2])
            }
            .disabled(!ready)
        case .playback:
            Group {
                keyButton(.rewind, "backward.fill", "Rewind").placed(rects[0])
                keyButton(.playPause, "playpause.fill", "Play or pause TV", style: model.state.isMarqueeInFront ? .accent : .raised).placed(rects[1])
                keyButton(.fastForward, "forward.fill", "Fast forward").placed(rects[2])
            }
            .disabled(!ready)
        case .launchers:
            ForEach(placement.moduleRects, id: \.module) { item in
                launcher(item.module)
                    .placed(item.rect)
            }
        }
    }

    private func keyButton(_ key: RemoteKey, _ symbol: String, _ label: String, style: RemoteKeyStyle = .raised, value: String? = nil) -> some View {
        RemoteKeyButton(spec: RemoteKeySpec(key: key, symbol: symbol, label: label), style: style, value: value)
    }

    /// Volume steps, and between them the key that mutes, which also shows the receiver's level while it is known.
    private func volumeKeys(_ rects: [CGRect]) -> some View {
        let volume = model.state.volume
        let muted = volume?.muted == true
        let level: String? = ready && !muted ? volume?.level.map { VolumeState.format($0) } : nil
        return Group {
            keyButton(.volumeDown, "minus", "Volume down").placed(rects[0])
            keyButton(.mute, "speaker.slash.fill", muted ? "Unmute TV" : "Mute TV", style: muted ? .accent : .raised, value: level).placed(rects[1])
            keyButton(.volumeUp, "plus", "Volume up").placed(rects[2])
        }
    }

    @ViewBuilder private func launcher(_ module: RemoteModule) -> some View {
        switch module {
        case .keyboard:
            RemoteActionKey(symbol: "keyboard", label: "TV keyboard") {
                stage.showKeyboard(true, followingTV: false)
            }
            .disabled(!ready)
            .accessibilityIdentifier("remote.keyboard")
        case .apps:
            RemoteActionKey(symbol: "square.grid.2x2", label: "Apps") {
                stage.path.append(.list(.apps))
            }
            .disabled(!ready || !model.state.allows(.launch(app: .string(""))))
            .accessibilityIdentifier("remote.apps")
        case .more:
            RemoteActionKey(symbol: "ellipsis", label: "More controls") {
                stage.path.append(.more)
            }
            .accessibilityIdentifier("remote.more")
        default:
            EmptyView()
        }
    }
}

// MARK: Notices

/// The pad's region: the pad and its switch, or, while the pad does not answer, the reason and the one thing that
/// fixes it, in its place and alone.
private struct PadRegion: View {
    let mode: RemotePadMode
    let ready: Bool
    let onMode: (RemotePadMode) -> Void

    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    private struct Banner {
        let text: String
        let action: String
        let perform: () -> Void
    }

    var body: some View {
        if let banner, !stage.editing {
            VStack(spacing: Space.s3) {
                Text(banner.text)
                    .textRole(.label)
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)
                Button(banner.action, action: banner.perform)
                    .buttonStyle(.pill)
            }
            .padding(.horizontal, Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote.status")
        } else {
            RemotePad(mode: mode, ready: ready, onMode: onMode)
        }
    }

    private var banner: Banner? {
        let name = model.current?.name ?? "The TV"
        if model.localNetworkDenied {
            return Banner(text: "Local Network access is off for this app, so it can't reach the TV.", action: "Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
        switch model.connection {
        case .offline:
            return Banner(text: "\(name) is off or out of reach.", action: "Wake") { model.wake() }
        case .incompatible:
            return Banner(text: "\(name) answered in a way this app doesn't understand. Update Marquee or LumaTV.", action: "Retry") { model.wake() }
        case .unpaired:
            return Banner(text: "\(name) no longer knows this phone.", action: "Pair again") { stage.path = [.pairing] }
        case .connected where model.state.power == .standby:
            return Banner(text: "\(name) is in standby.", action: "Turn on") { model.power() }
        default:
            return nil
        }
    }
}

/// No TV is chosen: an invitation to pair one.
private struct NoTV: View {
    let size: CGSize

    @Environment(RemoteStage.self) private var stage
    @Environment(\.theme) private var theme

    /// The glyph needs room; a small panel keeps the words and the button.
    private static let glyphMinHeight: CGFloat = 320
    private static let glyph: CGFloat = 56

    var body: some View {
        VStack(spacing: Space.s4) {
            if size.height >= Self.glyphMinHeight {
                Image(systemName: "tv")
                    .font(.system(size: Self.glyph, weight: .light))
                    .foregroundStyle(theme.ink3)
                    .accessibilityHidden(true)
            }
            Text("Pair this phone with a LumaTV to use it as the remote.")
                .textRole(.headline)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Button("Pair a TV") {
                stage.path = [.pairing]
            }
            .buttonStyle(.pill)
            .accessibilityIdentifier("remote.pair")
        }
        .padding(.horizontal, RemoteMetrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, RemoteMetrics.header)
    }
}
