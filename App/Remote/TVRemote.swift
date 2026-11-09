import LumaRemoteCore
import LumaRemoteKit
import SwiftUI

/// The LumaTV remote (DESIGN §8.7 Integrations), from LumaRemoteKit: off until turned on in Settings, then
/// a button beside the profile on Home opens it full screen. Marquee owns the `lumaremote://` pairing link
/// that the TV's QR code carries, so a code scanned with the Camera opens the remote here.
@MainActor @Observable
final class TVRemote {
    private(set) var isEnabled: Bool
    /// The remote, full screen over whatever the app shows.
    var isPresented = false
    /// Made again by Delete All Local Data, so the remote's own settings start over too.
    private(set) var model: RemoteModel
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let inMemory: Bool

    /// `inMemory` keeps the paired TVs and the remote's settings out of the Keychain and the saved
    /// defaults, so every UI test starts unpaired.
    init(storage: SessionStorage, inMemory: Bool) {
        self.storage = storage
        self.inMemory = inMemory
        isEnabled = storage.remoteEnabled
        model = Self.makeModel(inMemory: inMemory)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        storage.remoteEnabled = enabled
        if !enabled { isPresented = false }
    }

    /// Opens a pairing link. Opening one asks for the remote, so it turns the remote on; the remote then
    /// asks to confirm the pairing.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard model.open(url) else { return false }
        setEnabled(true)
        isPresented = true
        return true
    }

    /// Delete All Local Data: the paired TVs' keys and the remote's settings. The TVs keep listing the
    /// phone until it is removed there.
    func eraseAll() {
        isPresented = false
        isEnabled = false
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

/// The remote full screen, in the app's theme; it follows a theme change while open.
struct TVRemoteScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        LumaRemoteView(model: session.remote.model) { session.remote.isPresented = false }
            .lumaRemoteTheme(RemoteTheme(theme))
    }
}

/// Home's remote button, beside the profile button while the remote is on.
struct TVRemoteButton: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button("TV Remote", systemImage: "av.remote") {
            session.remote.isPresented = true
        }
        .accessibilityHint("Controls the LumaTV.")
        .accessibilityIdentifier("remote.button")
    }
}

/// The remote's page in Settings › Integrations: the switch that puts the remote on Home.
struct TVRemoteSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let remote = session.remote
        List {
            Section {
                Toggle("Remote on Home", isOn: Binding(get: { remote.isEnabled }, set: { remote.setEnabled($0) }))
                    .accessibilityIdentifier("remote.enabled")
            } footer: {
                Text("Controls a LumaTV on the same Wi-Fi: its keys, the keyboard, volume and a pointer moved with the iPhone or a touchpad. The remote pairs with the TV the first time it opens.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("LumaTV Remote")
        .navigationBarTitleDisplayMode(.inline)
    }
}
