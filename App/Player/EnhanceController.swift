import AVFoundation
import Observation
import VideoEngine

/// The picture enhancer of one title player (docs/DESIGN.md, Enhance picture): creates VideoEngine's
/// `PictureEnhancer` while the setting is on, keeps it on the player's item and tells it when to rest.
/// Only the model of an AVPlayer-backed title owns one; Live TV, trailers and the mini bar's picture do not.
@MainActor @Observable
final class EnhanceController {
    private(set) var state = EnhanceState.idle

    @ObservationIgnored private weak var layerView: PlayerLayerView?
    @ObservationIgnored private var enhancer: PictureEnhancer?
    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var active = true
    /// The engine's `enhance-probe` lines say what each scaler did; this app line says what the item got.
    @ObservationIgnored private var probed = false

    init(layerView: PlayerLayerView) {
        self.layerView = layerView
    }

    /// Starts, changes or stops the enhancer for the setting's options; the engine takes new options live.
    func configure(_ options: EnhanceOptions) {
        guard options.isEnabled else {
            stop()
            return
        }
        if let enhancer {
            enhancer.options = options
            return
        }
        guard let layerView else { return }
        let enhancer = PictureEnhancer(options: options, logger: EngineLog.logger)
        self.enhancer = enhancer
        layerView.setEnhancer(enhancer)
        let updates = enhancer.updates()
        task = Task { [weak self] in
            for await state in updates {
                guard let self else { return }
                self.changed(to: state)
            }
        }
        enhancer.setActive(active)
        if let item { attach(item) }
    }

    /// Every new item: a restart, a quality move, the next episode.
    func attach(_ item: AVPlayerItem) {
        self.item = item
        probed = false
        enhancer?.attach(to: item)
    }

    func detach() {
        item = nil
        enhancer?.detach()
    }

    /// Playing in the foreground in the full player; anything else leaves the plain picture and stops the
    /// engine's work.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        enhancer?.setActive(active)
    }

    func close() {
        stop()
    }

    private func stop() {
        task?.cancel()
        task = nil
        enhancer?.detach()
        layerView?.setEnhancer(nil)
        enhancer = nil
        state = .idle
    }

    /// One line for the stats screen; nil while the setting is off.
    var summary: String? {
        guard enhancer != nil else { return nil }
        switch state {
        case .idle:
            return "Waiting for a picture, or it already fills the screen"
        case .running(let plan):
            let scaler = plan.upscaler?.label ?? "No scaler"
            let size = "\(plan.sourceWidth)×\(plan.sourceHeight) → \(plan.outputWidth)×\(plan.outputHeight)"
            return "Running · \(scaler) · \(size) · sharpen \(Self.number(plan.sharpen)) · deband \(Self.number(plan.deband))"
        case .paused(let reason):
            return "Paused · " + (reason == .powerSaving ? "the phone is hot or in Low Power Mode" : "it cannot keep up")
        case .unavailable(let reason):
            return "Unavailable · " + reason.message
        }
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func changed(to state: EnhanceState) {
        self.state = state
        let name: String
        var reason: String?
        switch state {
        case .idle: name = "idle"
        case .running: name = "running"
        case .paused(let why):
            name = "paused"
            reason = why.rawValue
        case .unavailable(let why):
            name = "unavailable"
            reason = why.rawValue
        }
        Diag.event(.player, "enhance.state", ["state": name, "reason": reason, "outputs": item?.outputs.count])
        guard !probed, state != .idle else { return }
        probed = true
        var plan = ["result": name, "outputs": "\(item?.outputs.count ?? 0)"]
        if case .running(let running) = state {
            plan["scaler"] = running.upscaler?.rawValue ?? "none"
            plan["source"] = "\(running.sourceWidth)x\(running.sourceHeight)"
            plan["output"] = "\(running.outputWidth)x\(running.outputHeight)"
            plan["sharpen"] = Self.number(running.sharpen)
            plan["deband"] = Self.number(running.deband)
        } else {
            plan["reason"] = reason
        }
        Diag.event(.player, "enhance-probe", list: plan.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }
}
