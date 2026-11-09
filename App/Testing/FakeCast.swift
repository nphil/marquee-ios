#if DEBUG
import Foundation
import MarqueeCore

/// The UI tests' Chromecasts (`-marquee.uitest.cast YES`, which also turns the plugin on): four receivers,
/// as a home has, each of which connects at once and plays what it is given from the requested time, its clock running while
/// it plays. Release builds never activate it.
@MainActor
final class FakeCast: CastBackend {
    static var isActive: Bool { FakePlex.isActive && UserDefaults.standard.bool(forKey: "marquee.uitest.cast") }

    var onEvent: ((CastEvent) -> Void)?
    private(set) var mediaSessionID: Int?
    private var anchor: TimeInterval = 0
    private var anchorTime: TimeInterval = 0
    private var playing = false

    private static let devices = [
        CastDevice(id: "fake-cast", name: "Living Room TV", model: "Chromecast"),
        CastDevice(id: "fake-cast-2", name: "Bedroom Display", model: "Chromecast Ultra"),
        CastDevice(id: "fake-cast-3", name: "Office Monitor", model: "Chromecast"),
        CastDevice(id: "fake-cast-4", name: "Kitchen Hub", model: "Chromecast with Google TV"),
    ]

    func startDiscovery() { send(.devices(Self.devices)) }

    func stopDiscovery() {}

    func connect(_ device: CastDevice) { send(.connected(device)) }

    func disconnect(stopping: Bool) {
        mediaSessionID = nil
        playing = false
        send(.disconnected)
    }

    func load(_ load: CastLoad) {
        mediaSessionID = (mediaSessionID ?? 0) + 1
        move(to: load.startAt, playing: load.autoplay)
    }

    func play() { move(to: position, playing: true) }

    func pause() { move(to: position, playing: false) }

    func seek(to time: TimeInterval) { move(to: time, playing: playing) }

    private var position: TimeInterval {
        playing ? anchor + ProcessInfo.processInfo.systemUptime - anchorTime : anchor
    }

    private func move(to time: TimeInterval, playing: Bool) {
        anchor = time
        anchorTime = ProcessInfo.processInfo.systemUptime
        self.playing = playing
        guard let mediaSessionID else { return }
        send(.status(CastStatus(mediaSessionID: mediaSessionID, player: playing ? .playing : .paused, position: time)))
    }

    /// Answers on a later turn, as the SDK's callbacks do.
    private func send(_ event: CastEvent) {
        Task { @MainActor [weak self] in self?.onEvent?(event) }
    }
}
#endif
