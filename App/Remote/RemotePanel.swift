import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import SwiftUI

/// The floating remote's panel: the face, and the pages that open over it, in a navigation stack of their own
/// that opens and closes with the panel. The container that grows out of the button gives it its size.
struct RemotePanel: View {
    let size: CGSize

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var stage = stage
        let remote = session.remote
        let model = remote.model
        NavigationStack(path: $stage.path) {
            RemoteFace(size: size)
                .accessibilityAction(.escape) { remote.isPresented = false }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: RemotePage.self) { page in
                    RemotePageView(page: page)
                }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Larger text would not fit the header and the keys.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // The panel is already fitted above the keyboard.
        .ignoresSafeArea(.keyboard)
        .environment(model)
        .lumaRemoteTheme(RemoteTheme(theme))
        .tint(theme.accentText)
        .overlay(alignment: .top) {
            RemoteNotice()
                .padding(.top, RemoteMetrics.header)
        }
        .background {
            if model.settings.volumeButtons, model.connection == .connected {
                RemoteVolumeCatcher { model.volumeButton($0) }
                    .frame(width: 1, height: 1)
            }
        }
        // A link the app opened asks to pair here.
        .onChange(of: model.invite != nil, initial: true) { _, invited in
            if invited { stage.path = [.pairing] }
        }
        // The TV opening a text field brings the keyboard page up; closing it takes away only a page it brought.
        .onChange(of: model.state.ime.active) { _, active in
            if active, stage.path.last != .keyboard {
                stage.showKeyboard(true, followingTV: true)
            } else if !active, stage.keyboardFollowsTV {
                stage.showKeyboard(false, followingTV: false)
            }
        }
    }
}

/// The model's latest notice, for three seconds, and read out by VoiceOver.
private struct RemoteNotice: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let notice = model.notice {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            Text(notice.text)
                .textRole(.label)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .background(theme.glassRaised, in: shape)
                .overlay(shape.strokeBorder(theme.edge, lineWidth: 1))
                .padding(.horizontal, Space.s4)
                .onTapGesture { model.dismissNotice() }
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement(notice.text).post()
                    try? await Task.sleep(for: .seconds(3))
                    if model.notice?.id == notice.id { model.dismissNotice() }
                }
                .accessibilityIdentifier("remote.notice")
        }
    }
}
