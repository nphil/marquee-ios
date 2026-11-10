import LumaRemoteCore
import LumaRemoteKit
import SwiftUI

enum RemoteAccess: String, CaseIterable, Identifiable {
    case miniBar, homeButton
    var id: String { rawValue }
    var title: String { self == .miniBar ? "Mini Bar" : "Home Button" }
}

/// The optional LumaTV remote, opened from the selected access point or its pairing link.
@MainActor @Observable
final class TVRemote {
    private(set) var isEnabled: Bool
    private(set) var access: RemoteAccess
    /// The remote's sheet over whatever the app shows.
    var isPresented = false
    /// Whether the sheet opened from Home's remote button, so it zooms out of that button and back into it.
    private(set) var zoomsFromButton = false
    var opensAfterSettings = false
    /// Made again by Delete All Local Data, so the remote's own settings start over too.
    private(set) var model: RemoteModel
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let inMemory: Bool
    @ObservationIgnored private var appInForeground = false

    /// `inMemory` keeps the paired TVs and the remote's settings out of the Keychain and the saved
    /// defaults, so every UI test starts unpaired.
    init(storage: SessionStorage, inMemory: Bool) {
        self.storage = storage
        self.inMemory = inMemory
        isEnabled = storage.remoteEnabled
        access = storage.remoteAccess
        model = Self.makeModel(inMemory: inMemory)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        storage.remoteEnabled = enabled
        if !enabled { isPresented = false }
        refreshLifecycle()
    }

    func setForeground(_ foreground: Bool) {
        appInForeground = foreground
        refreshLifecycle()
    }

    func refreshLifecycle() {
        if isEnabled && appInForeground {
            model.activate()
        } else {
            model.deactivate()
        }
    }

    func setAccess(_ access: RemoteAccess) {
        self.access = access
        storage.remoteAccess = access
    }

    /// Opens the remote. Only Home's remote button asks for the zoom; the mini bar, a pairing link and
    /// Settings' Open Remote use the sheet's own motion.
    func present(fromButton: Bool = false) {
        if !isPresented { zoomsFromButton = fromButton }
        isPresented = true
    }

    /// Opens a pairing link. Opening one asks for the remote, so it turns the remote on; the remote then
    /// asks to confirm the pairing.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard model.open(url) else { return false }
        setEnabled(true)
        present()
        return true
    }

    /// Delete All Local Data: the paired TVs' keys and the remote's settings. The TVs keep listing the
    /// phone until it is removed there.
    func eraseAll() {
        model.deactivate()
        isPresented = false
        isEnabled = false
        access = .miniBar
        if !inMemory {
            let store = KeychainPairingStore()
            for tv in (try? store.all()) ?? [] { try? store.remove(tv.id) }
            UserDefaults.standard.removePersistentDomain(forName: RemoteSettings.suiteName)
        }
        model = Self.makeModel(inMemory: inMemory)
    }

    private static func makeModel(inMemory: Bool) -> RemoteModel {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var services = RemoteModel.Services.live()
        var settings = RemoteSettings()
        if inMemory {
            services.store = MemoryPairingStore()
            let suite = "com.nphil.marquee.uitest.remote"
            // Nil only for the app's own bundle identifier or the global domain.
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            settings = RemoteSettings(defaults: defaults)
        }
        return RemoteModel(app: "Marquee \(version)", services: services, settings: settings)
    }
}

extension RemoteTheme {
    /// The remote in Marquee's theme: canvas, glass for its surfaces, the inks, accent and status roles,
    /// card and control radii, and Manrope for titles as in the rest of the app.
    init(_ theme: Theme) {
        self.init(
            palette: Palette(
                canvas: theme.canvas, surface: theme.glass, surfaceRaised: theme.glassRaised, edge: theme.edge,
                ink: theme.ink, ink2: theme.ink2, ink3: theme.ink3, accent: theme.accent, accentInk: theme.accentInk,
                focus: theme.focus, positive: theme.positive, warning: theme.warning, danger: theme.danger, info: theme.info
            ),
            colorScheme: theme.mode.colorScheme,
            radii: Radii(surface: Radius.card, control: Radius.control),
            typefaces: Typefaces(
                regular: Manrope.medium.rawValue,
                medium: Manrope.medium.rawValue,
                semibold: Manrope.semiBold.rawValue,
                bold: Manrope.bold.rawValue,
                titlesOnly: true
            )
        )
    }
}

/// The remote as a sheet, in the app's theme; it follows a theme change while open.
struct TVRemoteScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        // The app keeps the link up (TVRemote.refreshLifecycle). Left to the screen, closing the sheet would
        // drop the link, and the mini bar would read Offline until the app asked for it again.
        LumaRemoteView(model: session.remote.model, managesLifecycle: false) { session.remote.isPresented = false }
            .lumaRemoteTheme(RemoteTheme(theme))
            // The kit's bar starts at the sheet's top edge, where the system's rounded corners (a 38 pt
            // continuous curve, measured on iOS 27) crowd the 56 pt close and power buttons. The sides
            // keep 16 pt, so the top keeps the same and the buttons clear the corner evenly. In landscape
            // the sheet is full screen and the side safe areas keep the buttons off the display corners.
            .safeAreaPadding(.top, verticalSizeClass == .compact ? 0 : Space.inset)
    }
}

/// A compact entry point that adopts the system's inline placement when the tab bar minimises.
struct TVRemoteMiniBar: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String {
        switch session.remote.model.connection {
        case .none: "Not paired"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .offline: "Offline"
        case .incompatible: "Incompatible"
        case .unpaired: "Pair again"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s2) {
                Image(systemName: "tv")
                    .foregroundStyle(theme.accent)
                if placement != .inline {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                }
                Text(session.remote.model.current?.name ?? "LumaTV")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.ink2)
            }
            .padding(.horizontal, Space.s3)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -35 && abs(value.translation.height) > abs(value.translation.width) {
                open()
            }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TV Remote, \(session.remote.model.current?.name ?? "LumaTV"), \(status)")
        .accessibilityHint("Opens the TV remote.")
        .accessibilityIdentifier("remote.miniBar")
    }

    private func open() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            session.remote.present()
        }
    }
}

/// Home's remote button, beside the profile button while the remote is on. It wears the profile button's
/// shape (a 36 pt disc, a 2 pt gap and a 2 pt accent ring, 44 pt across) so the two read as a pair,
/// and stands outside the bar's glass capsule as the profile button does.
struct TVRemoteButton: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            session.remote.present(fromButton: true)
        } label: {
            Image(systemName: "appletvremote.gen4.fill")
                // 40% of the disc, the player controls' glyph proportion (Size.controlGlyph).
                .font(.system(size: (Size.target - Space.s3) * Size.controlGlyph / Size.control, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(width: Size.target - Space.s3, height: Size.target - Space.s3)
                .background(theme.sheet, in: Circle())
                .padding(Space.s1)
                .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
                .frame(width: Size.target, height: Size.target)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("TV Remote")
        .accessibilityHint("Controls the LumaTV.")
        .accessibilityShowsLargeContentViewer {
            Label("TV Remote", systemImage: "appletvremote.gen4.fill")
        }
        .accessibilityIdentifier("remote.button")
    }
}

/// The LumaTV remote's settings and pairing entry point.
struct TVRemoteSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let remote = session.remote
        List {
            Section {
                Toggle("LumaTV Remote", isOn: Binding(get: { remote.isEnabled }, set: { remote.setEnabled($0) }))
                    .accessibilityIdentifier("remote.enabled")
                if remote.isEnabled {
                    Picker("Remote Access", selection: Binding(get: { remote.access }, set: { remote.setAccess($0) })) {
                        ForEach(RemoteAccess.allCases) { access in
                            Text(access.title).tag(access)
                        }
                    }
                    .accessibilityIdentifier("remote.access")

                    Button("Open Remote / Pair TV") {
                        remote.opensAfterSettings = true
                        session.showsSettings = false
                    }
                    .accessibilityIdentifier("remote.setup")
                }
            } footer: {
                Text("Controls a LumaTV on the same Wi-Fi. The selected entry appears when the phone is at home. Pair or open the remote here at any time.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("LumaTV Remote")
        .navigationBarTitleDisplayMode(.inline)
    }
}
