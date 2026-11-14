import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit

/// The big-screen plugin: XR glasses and TVs (DESIGN §8.9). Glasses such as the Viture Pro, or a TV on
/// USB-C video out or an HDMI adapter, reach the iPhone as an external display. With the plugin on, the
/// first connection of a display asks whether to use Marquee on it; if so it gets Marquee's own screen and
/// the iPhone becomes an eyes-free remote. Otherwise iOS mirrors the phone, as it does with the plugin off.
/// AirPlay mirroring is not handled: it is not a wired display, and whether iOS offers its screen to this
/// scene is untested (DEVICE-TEST).
@MainActor @Observable
final class GlassesCenter {
    private(set) var isEnabled: Bool
    private(set) var use: BigScreenUse
    /// What a display that was not told apart yet is taken for.
    private(set) var defaultKind: DisplayKind
    private(set) var displays: DisplayMemory
    private(set) var tiltEnabled: Bool
    /// The display's scene is up, whether or not it shows Marquee yet.
    private(set) var hasScene = false
    /// The connected display, while its scene is up and not mirroring.
    private(set) var display: DisplayIdentity?
    /// What the display is, once decided: the remembered answer or the page's choice.
    private(set) var kind: DisplayKind?
    /// Marquee's screen is up and the remote drives it.
    private(set) var isConnected = false
    /// The phone app was chosen over the remote; the display button brings the remote back.
    var remoteHidden = false
    /// Said once, the first time the person puts the remote away; the phone app shows it as a toast.
    private(set) var leaveHint: String?
    /// "Use Marquee on this display?" waits for an answer.
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
    @ObservationIgnored private weak var screen: UIScreen?
    /// The display was handed back to iOS to mirror, and stays so until it is unplugged.
    @ObservationIgnored private var mirroring = false
    @ObservationIgnored private var unplugObserver: NSObjectProtocol?
    @ObservationIgnored private(set) weak var session: AppSession?
    @ObservationIgnored private(set) weak var themeStore: ThemeStore?
    #if DEBUG
    @ObservationIgnored private var simulation: GlassesSimulation?
    @ObservationIgnored fileprivate var simulatedIdentity: DisplayIdentity?
    #endif

    /// UIKit makes the scene delegate, so it finds the plugin here.
    static weak var live: GlassesCenter?

    init(storage: SessionStorage) {
        self.storage = storage
        isEnabled = storage.glassesEnabled
        use = storage.glassesUse
        defaultKind = storage.glassesKind
        displays = storage.glassesDisplays
        tiltEnabled = storage.glassesTilt
    }

    func setEnabled(_ enabled: Bool) {
        storage.glassesEnabled = enabled
        isEnabled = enabled
        if !enabled { asksToUse = false }
        updateRegistration()
    }

    /// The page's "When a Display Connects": what a display with no remembered answer is used for.
    func setUse(_ use: BigScreenUse) {
        storage.glassesUse = use
        self.use = use
        asksToUse = false
        mirroring = false
        updateRegistration()
        evaluate()
    }

    /// The page's "Display Type". While a display is connected it is that display's, remembered; otherwise
    /// it is what a new display is taken for.
    func setKind(_ kind: DisplayKind) {
        guard let display else {
            storage.glassesKind = kind
            defaultKind = kind
            return
        }
        remember(display, kind: kind, use: displays.entry(for: display)?.use ?? .marquee)
        evaluate()
    }

    /// The kind the page shows: the connected display's, else the default for a new one.
    var shownKind: DisplayKind {
        display.flatMap { displays.entry(for: $0)?.kind } ?? kind ?? defaultKind
    }

    /// An answer from the first-connection question: glasses, a TV, or nil to mirror.
    func answer(_ kind: DisplayKind?) {
        guard let display else {
            asksToUse = false
            return
        }
        remember(display, kind: kind ?? shownKind, use: kind == nil ? .mirror : .marquee)
        asksToUse = false
        evaluate()
    }

    func forget(_ key: String) {
        displays.forget(key: key)
        storage.glassesDisplays = displays
        mirroring = false
        updateRegistration()
        evaluate()
    }

    func setTilt(_ enabled: Bool) {
        storage.glassesTilt = enabled
        tiltEnabled = enabled
    }

    /// Delete All Local Data: the plugin goes back to off and asks again.
    func reset() {
        setEnabled(false)
        use = storage.glassesUse
        defaultKind = storage.glassesKind
        displays = storage.glassesDisplays
        tiltEnabled = storage.glassesTilt
    }

    private func remember(_ display: DisplayIdentity, kind: DisplayKind, use: BigScreenUse) {
        displays.remember(display, kind: kind, use: use)
        storage.glassesDisplays = displays
    }

    // MARK: What the display is

    /// The question the phone asks on a first connection, naming the display as iOS describes it.
    var question: String { display?.question ?? "Use Marquee on this display?" }

    /// The kind the canvas is laid out for: decided, else the page's guess while the question waits.
    var layoutKind: DisplayKind { kind ?? shownKind }

    var metrics: BigScreenMetrics {
        let kind = layoutKind
        let width = display?.pixelWidth ?? 0
        let height = display?.pixelHeight ?? 0
        return BigScreenMetrics(
            layout: BigScreenLayout(kind: kind, pixelWidth: width, pixelHeight: height),
            pixels: kind == .tv && width > 0 ? CGSize(width: width, height: height) : nil
        )
    }

    /// The screen a TV plays on, for the player's HDR and frame-rate decisions. Glasses decide as the phone.
    var tvScreen: UIScreen? {
        isConnected && kind == .tv ? screen : nil
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
        if unplugObserver == nil {
            unplugObserver = NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard let center = GlassesCenter.live, center.mirroring else { return }
                    center.mirroring = false
                    center.updateRegistration()
                }
            }
        }
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
        // Off, iOS mirrors the phone. While asking, the display shows the question until it is answered. A
        // display answered Mirror hands itself back and stays off until it is unplugged; with Mirror as the
        // page's choice the scene is still offered while some display is remembered for Marquee.
        registration?.isEnabled = !mirroring && (use != .mirror || displays.displays.contains { $0.use == .marquee })
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

    /// The display's scene connected. A display not seen before, with the page on Ask, makes the phone ask
    /// what it is for.
    func sceneConnected(screen: UIScreen) {
        self.screen = screen
        begin(Self.identity(of: screen))
    }

    private func begin(_ display: DisplayIdentity) {
        hasScene = true
        mirroring = false
        self.display = display
        evaluate()
    }

    /// Decides what the connected display is for, from its remembered answer or the page's choice, and
    /// brings Marquee's screen up or down to match. A connected display is not taken down by Ask, which
    /// only concerns the next connection.
    private func evaluate() {
        guard hasScene, let display else { return }
        switch DisplayOutcome.decide(for: display, memory: displays, use: use, defaultKind: defaultKind) {
        case .ask:
            if !isConnected { asksToUse = true }
        case .marquee(let kind):
            asksToUse = false
            self.kind = kind
            if !isConnected { connected() }
        case .mirror:
            asksToUse = false
            if isConnected { disconnected() }
            kind = nil
            self.display = nil
            mirroring = true
            registration?.isEnabled = false
        }
    }

    func sceneDisconnected() {
        hasScene = false
        asksToUse = false
        if isConnected { disconnected() }
        display = nil
        kind = nil
    }

    /// What the display's remote button and the remote's screen show.
    var symbol: String { layoutKind == .tv ? "tv" : "eyeglasses" }

    var remoteTitle: String { layoutKind == .tv ? "Big Screen Remote" : "Glasses Remote" }

    /// What iOS says of a display: its pixels and refresh rate, and a name where the audio route over HDMI
    /// carries one (a generic "HDMI" is no name).
    private static func identity(of screen: UIScreen) -> DisplayIdentity {
        let pixels = screen.nativeBounds.size
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .HDMI }
        let name = output?.portName.caseInsensitiveCompare("HDMI") == .orderedSame ? nil : output?.portName
        return DisplayIdentity(
            pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
            refreshRate: screen.maximumFramesPerSecond, name: name
        )
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

    /// The person put the remote away (its Phone App button, swipe or Settings): the first time, the phone
    /// app says that the screen keeps running and where the remote comes back from.
    func leaveRemote() {
        showPhoneApp()
        guard !storage.glassesLeftRemote else { return }
        storage.glassesLeftRemote = true
        let words = layoutKind == .tv ? "The TV keeps its screen. The TV button" : "The glasses keep their screen. The glasses button"
        leaveHint = "\(words) on Home brings the remote back."
    }

    func clearLeaveHint() {
        leaveHint = nil
    }

    /// The glasses button on the phone brings the remote back.
    func showRemote() {
        remoteHidden = false
        syncRemote()
    }

    // MARK: Volume

    /// The glasses show the level as the buttons, or a linked phone's remote, change it.
    private func watchVolume() {
        let audio = AVAudioSession.sharedInstance()
        volume = audio.outputVolume
        volumeObservation = audio.observe(\.outputVolume, options: [.new]) { _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor in GlassesCenter.live?.showVolume(level) }
        }
    }

    /// Puts the level bar on the big screen for a moment; the players' own level shows through here when
    /// the system volume cannot be set.
    func showVolume(_ level: Float) {
        guard isConnected else { return }
        volume = level
        volumeChanged = .now
    }
}

#if DEBUG
/// UI tests stand in for a connected display: `ask` connects one that asks what it is for; `remote`
/// connects it for Marquee; `phone` does too, with the phone app picked over the remote; `canvas` also
/// draws the screen over the phone for screenshots. `-marquee.uitest.glassesDisplay` sets what it is,
/// as `glasses` (the default, 1920 × 1080) or `tv:3840x2160`.
enum GlassesSimulation: String {
    case ask, remote, phone, canvas
}

extension GlassesCenter {
    func simulate(arguments: UserDefaults) {
        guard let mode = arguments.string(forKey: "marquee.uitest.glasses").flatMap(GlassesSimulation.init(rawValue:)) else { return }
        simulation = mode
        let (kind, identity) = Self.simulatedDisplay(arguments.string(forKey: "marquee.uitest.glassesDisplay"))
        simulatedIdentity = identity
        setEnabled(true)
        if mode == .ask {
            setUse(.ask)
        } else {
            // A known display, so nothing asks.
            remember(identity, kind: kind, use: .marquee)
            setUse(.marquee)
        }
    }

    private static func simulatedDisplay(_ spec: String?) -> (DisplayKind, DisplayIdentity) {
        let parts = spec?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
        if parts.first == "tv" {
            let size = (parts.count > 1 ? parts[1] : "3840x2160").split(separator: "x").compactMap { Int($0) }
            if size.count == 2 { return (.tv, DisplayIdentity(pixelWidth: size[0], pixelHeight: size[1], refreshRate: 60)) }
        }
        return (.glasses, DisplayIdentity(pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60))
    }

    private func simulate(_ mode: GlassesSimulation) {
        guard session?.state == .ready, !hasScene, let simulatedIdentity else { return }
        begin(simulatedIdentity)
        if mode == .phone { showPhoneApp() }
        if mode == .canvas { GlassesPreview.show(center: self) }
        if let page = UserDefaults.standard.string(forKey: "marquee.uitest.glassesPage"), let navigator {
            Task { await navigator.openForUITest(page) }
        }
    }
}
#endif
