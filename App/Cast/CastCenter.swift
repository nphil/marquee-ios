import Foundation
import MarqueeCore
import Observation

/// A Chromecast found on the network.
struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    /// "Chromecast Ultra" and the like, which says what it decodes.
    let model: String?
}

/// What the player hands a receiver.
struct CastLoad {
    var stream: CastStream
    var title: String
    var subtitle: String?
    var poster: URL?
    var isEpisode: Bool
    var duration: TimeInterval
    var startAt: TimeInterval
    var autoplay: Bool
}

enum CastEvent {
    case devices([CastDevice])
    case connected(CastDevice)
    /// The session did not start, or it ended: the receiver went away, or a sender left it.
    case disconnected
    case status(CastStatus)
}

/// Google's Cast SDK, or the UI tests' stand-in.
@MainActor
protocol CastBackend: AnyObject {
    var onEvent: ((CastEvent) -> Void)? { get set }
    /// The receiver's id for what it holds now, if anything.
    var mediaSessionID: Int? { get }
    func startDiscovery()
    func stopDiscovery()
    func connect(_ device: CastDevice)
    /// Leaves the session, stopping what plays on the receiver when `stopping`.
    func disconnect(stopping: Bool)
    func load(_ load: CastLoad)
    func play()
    func pause()
    func seek(to time: TimeInterval)
}

/// The open player, which casts while the center holds a session.
@MainActor
protocol CastPlayer: AnyObject {
    func castConnected(_ device: CastDevice)
    func castDisconnected()
    func castStatus(_ status: CastStatus)
}

/// The Chromecast plugin (DESIGN §8.7). Off until turned on in Settings; while on, it looks for
/// receivers only while the player or the plugin's page is open, and holds the session the player
/// casts to. The SDK starts with the first search, so a phone that never turns it on never loads it.
@MainActor @Observable
final class CastCenter {
    enum Link: Equatable {
        case none
        case connecting(CastDevice)
        case connected(CastDevice)
    }

    private(set) var isEnabled: Bool
    private(set) var devices: [CastDevice] = []
    private(set) var link: Link = .none
    @ObservationIgnored weak var player: (any CastPlayer)?
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private var backend: (any CastBackend)?
    @ObservationIgnored private var searches = 0

    init(storage: SessionStorage) {
        self.storage = storage
        isEnabled = storage.castEnabled
        #if DEBUG
        // `-marquee.uitest.cast YES` turns it on for one launch.
        if FakeCast.isActive { isEnabled = true }
        #endif
    }

    var device: CastDevice? {
        if case .connected(let device) = link { return device }
        return nil
    }

    var mediaSessionID: Int? { backend?.mediaSessionID }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        storage.castEnabled = enabled
        if enabled {
            if searches > 0 { madeBackend()?.startDiscovery() }
        } else {
            disconnect()
            backend?.stopDiscovery()
            devices = []
        }
    }

    /// Looks for receivers until the matching `endSearch`.
    func beginSearch() {
        searches += 1
        guard isEnabled, searches == 1 else { return }
        madeBackend()?.startDiscovery()
    }

    func endSearch() {
        searches = max(0, searches - 1)
        guard searches == 0 else { return }
        backend?.stopDiscovery()
    }

    func connect(_ device: CastDevice) {
        guard isEnabled, link != .connected(device), let backend = madeBackend() else { return }
        if link != .none { backend.disconnect(stopping: true) }
        link = .connecting(device)
        backend.connect(device)
    }

    /// Back to the phone. A receiver someone else has taken over is left playing.
    func disconnect(stopping: Bool = true) {
        guard link != .none else { return }
        link = .none
        backend?.disconnect(stopping: stopping)
        player?.castDisconnected()
    }

    func load(_ load: CastLoad) { backend?.load(load) }
    func play() { backend?.play() }
    func pause() { backend?.pause() }
    func seek(to time: TimeInterval) { backend?.seek(to: time) }

    private func madeBackend() -> (any CastBackend)? {
        if let backend { return backend }
        let made = Self.makeBackend()
        made?.onEvent = { [weak self] event in self?.handle(event) }
        backend = made
        return made
    }

    private func handle(_ event: CastEvent) {
        switch event {
        case .devices(let found):
            devices = found
        case .connected(let device):
            // The player closed while the receiver was connecting.
            guard let player else {
                link = .none
                backend?.disconnect(stopping: true)
                return
            }
            link = .connected(device)
            player.castConnected(device)
        case .disconnected:
            guard link != .none else { return }
            link = .none
            player?.castDisconnected()
        case .status(let status):
            player?.castStatus(status)
        }
    }

    private static func makeBackend() -> (any CastBackend)? {
        #if DEBUG
        if FakeCast.isActive { return FakeCast() }
        #endif
        #if canImport(GoogleCast)
        return GoogleCastBackend()
        #else
        return nil
        #endif
    }
}
