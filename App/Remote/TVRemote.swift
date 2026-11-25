import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import SwiftUI

enum RemoteAccess: String, CaseIterable, Identifiable {
    case profileButton, miniBar
    var id: String { rawValue }
    var title: String { self == .miniBar ? "Mini Bar" : "Button by Profile" }

    /// The saved choice. The Mini Bar is the only one kept by name: the Home button of early builds
    /// (`homeButton`) and the floating button that followed (`floatingButton`) both became the button by the
    /// profile, and no saved choice means it too.
    init(stored raw: String?) {
        self = raw == Self.miniBar.rawValue ? .miniBar : .profileButton
    }
}

/// The optional LumaTV remote, opened from the selected access point or its pairing link.
@MainActor @Observable
final class TVRemote {
    private(set) var isEnabled: Bool
    private(set) var access: RemoteAccess
    /// The remote's panel over whatever the app shows.
    var isPresented = false
    var opensAfterSettings = false
    /// Where the panel grows from: the Home button's frame in the window, nil when something else opened it.
    private(set) var origin: CGRect?
    /// The panel's rectangle as fractions of the window; nil until it has been moved or resized.
    private(set) var panel: PanelFractions?
    /// The groups of controls the panel shows.
    private(set) var modules: Set<RemoteModule>
    private(set) var mode: RemotePadMode
    /// The touchpad's pointer follows the phone's turns (the air mouse) instead of a finger.
    private(set) var airMouse: Bool
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
        panel = storage.remotePanel
        modules = storage.remoteModules
        mode = storage.remoteMode
        airMouse = storage.remoteAirMouse
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

    func setPanel(_ panel: PanelFractions) {
        self.panel = panel
        storage.remotePanel = panel
    }

    func setModules(_ modules: Set<RemoteModule>) {
        self.modules = modules
        storage.remoteModules = modules
    }

    func setMode(_ mode: RemotePadMode) {
        self.mode = mode
        storage.remoteMode = mode
    }

    func setAirMouse(_ on: Bool) {
        airMouse = on
        storage.remoteAirMouse = on
    }

    /// Arrange › Reset: the default panel, every module and the D-pad.
    func resetLayout() {
        panel = nil
        modules = .all
        mode = .dpad
        storage.resetRemoteLayout()
    }

    /// Opens the panel, growing from `button` when the Home button opened it.
    func present(from button: CGRect? = nil) {
        origin = button
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
        access = .profileButton
        panel = nil
        modules = .all
        mode = .dpad
        airMouse = false
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
    /// The remote in Marquee's theme: the panel's own fill for the canvas, glass for its surfaces, the inks,
    /// accent and status roles, card and control radii, and Manrope for titles as in the rest of the app.
    init(_ theme: Theme) {
        self.init(
            palette: Palette(
                canvas: theme.remotePanel, surface: theme.glass, surfaceRaised: theme.glassRaised, edge: theme.edge,
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

/// A compact entry point that adopts the system's inline placement when the tab bar minimises.
struct TVRemoteMiniBar: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

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
        session.remote.present()
    }
}

/// The remote's button in Home's header, left of the profile button: it opens the remote's panel, which grows
/// out of it. Drawn as the profile button is: a theme-coloured ring around a disc.
struct TVRemoteButton: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            session.remote.model.feedback.tick()
            session.remote.present(from: frame)
        } label: {
            Image(systemName: "appletvremote.gen4.fill")
                // 40% of the disc, the player controls' glyph proportion (Size.controlGlyph).
                .font(.system(size: (Size.barButton - 2 * Space.s1) * Size.controlGlyph / Size.control, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(width: Size.barButton - 2 * Space.s1, height: Size.barButton - 2 * Space.s1)
                .background(theme.sheet, in: Circle())
                .padding(Space.s1)
                .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
                .frame(width: Size.barButton, height: Size.barButton)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
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
                Text("Controls a LumaTV on the same Wi-Fi. The remote opens from a button in Home's header beside the profile button, or from the Mini Bar above the tabs, which appears when the phone is at home. Pair or open the remote here at any time.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("LumaTV Remote")
        .navigationBarTitleDisplayMode(.inline)
    }
}
