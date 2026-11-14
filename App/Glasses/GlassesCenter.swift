import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit

/// The XR glasses plugin (DESIGN §8.9). Glasses such as the Viture Pro reach the iPhone as an external
/// display. With the plugin on, the first connection asks whether to use them as glasses; if so they get
/// Marquee's own screen and the iPhone becomes an eyes-free remote. Otherwise iOS mirrors the phone, as
/// it does with the plugin off.
@MainActor @Observable
final class GlassesCenter {
    private(set) var isEnabled: Bool
    private(set) var use: GlassesUse
    private(set) var tiltEnabled: Bool
    /// The glasses' scene is up, whether or not it shows Marquee yet.
    private(set) var hasScene = false
    /// Marquee's glasses screen is up and the remote drives it.
    private(set) var isConnected = false
    /// The phone app was chosen over the remote; the glasses button brings the remote back.
    var remoteHidden = false
    /// "Use as XR glasses?" waits for an answer.
    var asksToUse = false
    /// The glasses' pages; made when they connect.
    private(set) var navigator: GlassesNavigator?
    /// The system volume while the glasses are connected, and when it last changed.
    private(set) var volume: Float = 0
    private(set) var volumeChanged: Date?

    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private var registration: UISceneAccessoryRegistration?
    @ObservationIgnored private var registering: Task<Void, Never>?
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    @ObservationIgnored private let takeover = GlassesTakeover()
    @ObservationIgnored private(set) weak var session: AppSession?
    @ObservationIgnored private(set) weak var themeStore: ThemeStore?
    #if DEBUG
    @ObservationIgnored private var simulation: GlassesSimulation?
    #endif

    /// UIKit makes the scene delegate, so it finds the plugin here.
    static weak var live: GlassesCenter?

    init(storage: SessionStorage) {
        self.storage = storage
        isEnabled = storage.glassesEnabled
        use = storage.glassesUse
        tiltEnabled = storage.glassesTilt
    }

    func setEnabled(_ enabled: Bool) {
        storage.glassesEnabled = enabled
        isEnabled = enabled
        if !enabled { asksToUse = false }
        updateRegistration()
    }

    func setUse(_ use: GlassesUse) {
        storage.glassesUse = use
        self.use = use
        asksToUse = false
        updateRegistration()
        if use == .glasses, hasScene, !isConnected { connected() }
    }

    func setTilt(_ enabled: Bool) {
        storage.glassesTilt = enabled
        tiltEnabled = enabled
    }

    /// Delete All Local Data: the plugin goes back to off and asks again.
    func reset() {
        setEnabled(false)
        use = storage.glassesUse
        tiltEnabled = storage.glassesTilt
    }

    /// The remote takes the phone while the glasses show Marquee, a server is chosen, and the phone app
    /// was not picked instead.
    var showsRemote: Bool {
        isConnected && !remoteHidden && session?.state == .ready
    }

    // MARK: The display

    /// Offers the glasses' scene to iOS. The offer hangs from the phone window's root controller, which
    /// exists once the phone's screen is up, so this runs on every activation and does nothing once made.
    func phoneReady(session: AppSession, themeStore: ThemeStore) {
        self.session = session
        self.themeStore = themeStore
        Self.live = self
        #if DEBUG
        if let simulation {
            simulate(simulation)
            return
        }
        #endif
        updateRegistration()
    }

    private func updateRegistration() {
        #if DEBUG
        if simulation != nil { return }
        #endif
        guard isEnabled else {
            registration?.isEnabled = false
            return
        }
        if registration == nil {
            guard let root = Self.phoneRoot() else {
                retryRegistration()
                return
            }
            let configuration = UISceneConfiguration(name: "Glasses", sessionRole: .windowExternalDisplayNonInteractive)
            configuration.delegateClass = GlassesSceneDelegate.self
            registration = root.registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
        }
        // Off, iOS mirrors the phone. While asking, the glasses show the question until it is answered.
        registration?.isEnabled = use != .mirror
    }

    /// The phone's window has no root controller for a moment at launch.
    private func retryRegistration() {
        guard registering == nil else { return }
        registering = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.registering = nil
            self?.updateRegistration()
        }
    }

    /// The phone's own window scene, which also carries the remote.
    static func phoneScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func phoneRoot() -> UIViewController? {
        guard let scene = phoneScene() else { return nil }
        let windows = scene.windows.filter { !($0 is GlassesTakeover.Window) }
        return (scene.keyWindow ?? windows.first)?.rootViewController
    }

    /// The glasses' scene connected. The first time, the phone asks what it is for.
    func sceneConnected() {
        hasScene = true
        switch use {
        case .ask: asksToUse = true
        case .glasses: connected()
        case .mirror: break
        }
    }

    func sceneDisconnected() {
        hasScene = false
        asksToUse = false
        if isConnected { disconnected() }
    }

    private func connected() {
        guard let session else { return }
        isConnected = true
        remoteHidden = false
        let navigator = GlassesNavigator(session: session, center: self)
        self.navigator = navigator
        navigator.start()
        session.player.onGlasses = true
        // The phone locking ends the glasses' picture, so the phone stays awake while they are on.
        UIApplication.shared.isIdleTimerDisabled = true
        watchVolume()
        syncRemote()
    }

    /// What played goes on on the phone, paused.
    private func disconnected() {
        isConnected = false
        navigator?.close()
        navigator = nil
        session?.player.onGlasses = false
        UIApplication.shared.isIdleTimerDisabled = false
        volumeObservation?.invalidate()
        volumeObservation = nil
        volumeChanged = nil
        syncRemote()
    }

    /// Puts up or takes down the remote's window over the phone app.
    func syncRemote() {
        if showsRemote, let store = themeStore, let navigator {
            takeover.show(navigator: navigator, store: store)
        } else {
            takeover.hide()
        }
    }

    /// The remote's "Phone App" gesture: the phone app comes back while the glasses keep their screen.
    func showPhoneApp() {
        remoteHidden = true
        syncRemote()
    }

    /// The glasses button on the phone brings the remote back.
    func showRemote() {
        remoteHidden = false
        syncRemote()
    }

    // MARK: Volume

    /// Read only: the volume buttons keep their own job, and the glasses show the level as it changes.
    private func watchVolume() {
        let audio = AVAudioSession.sharedInstance()
        volume = audio.outputVolume
        volumeObservation = audio.observe(\.outputVolume, options: [.new]) { _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor in
                guard let center = GlassesCenter.live, center.isConnected else { return }
                center.volume = level
                center.volumeChanged = .now
            }
        }
    }
}

#if DEBUG
/// UI tests stand in for connected glasses: `ask` connects a display that asks what it is for; `remote`
/// connects it as glasses; `phone` does too, with the phone app picked over the remote; `canvas` also
/// draws the glasses' screen over the phone for screenshots.
enum GlassesSimulation: String {
    case ask, remote, phone, canvas
}

extension GlassesCenter {
    func simulate(arguments: UserDefaults) {
        guard let mode = arguments.string(forKey: "marquee.uitest.glasses").flatMap(GlassesSimulation.init(rawValue:)) else { return }
        simulation = mode
        setEnabled(true)
        setUse(mode == .ask ? .ask : .glasses)
    }

    private func simulate(_ mode: GlassesSimulation) {
        guard session?.state == .ready, !hasScene else { return }
        sceneConnected()
        if mode == .phone { showPhoneApp() }
        if mode == .canvas { GlassesPreview.show(center: self) }
        if let page = UserDefaults.standard.string(forKey: "marquee.uitest.glassesPage"), let navigator {
            Task { await navigator.openForUITest(page) }
        }
    }
}
#endif
