import AVFoundation
import MarqueeCore
import Observation
import UIKit
import VideoEngine

/// What this iPhone plays, as MarqueeCore's `DeviceCapabilities`, from the engine's hardware snapshot.
/// The snapshot is read at launch, at each playback start and whenever heat, Low Power Mode or HDR
/// eligibility change.
@MainActor @Observable
final class PlaybackCapabilities {
    /// The latest snapshot, for Playback info.
    private(set) var hardware: HardwareCapabilities?

    /// Set while AirPlay or an external screen shows the player's video.
    static var externalPlaybackActive = false

    @ObservationIgnored private let provider = LiveHardwareCapabilityProvider(display: { await PlaybackCapabilities.display() })
    @ObservationIgnored private var watch: Task<Void, Never>?

    /// Reads the device now, so a route is decided for the screen and power state of this moment.
    func current() async -> DeviceCapabilities {
        let snapshot = await provider.snapshot()
        hardware = snapshot
        return Self.device(snapshot)
    }

    func startWatching() {
        guard watch == nil else { return }
        let provider = provider
        watch = Task { [weak self] in
            let first = await provider.snapshot()
            self?.hardware = first
            for await snapshot in provider.changes() {
                self?.hardware = snapshot
            }
        }
    }

    /// Plex reports neither the HEVC sample entry nor the decoder configuration, so the probe cannot
    /// judge one file; the per-codec answers decide. The remux keeps Dolby Vision 5 and 8 records and
    /// carries text subtitles, and the app draws picture subtitles itself.
    nonisolated static func device(_ hardware: HardwareCapabilities) -> DeviceCapabilities {
        let decode = hardware.decode
        return DeviceCapabilities(
            hevc: decode.hevc != HardwareCapabilities.Support.none,
            hevcMain10: decode.hevc10 != HardwareCapabilities.Support.none,
            av1: decode.av1 == .hardware,
            hdrDisplay: hardware.display.hdrPlaybackEligible,
            dolbyVisionProfiles: decode.dolbyVisionHEVC == .hardware ? [5, 8] : [],
            canRemux: true,
            remuxConvertsAudio: true,
            remuxKeepsDolbyVision: true,
            remuxCarriesTextSubtitles: true,
            drawsImageSubtitles: true
        )
    }

    private static func display() -> HardwareCapabilities.Display {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // On a TV the picture goes to the TV, so its screen decides. AVPlayer reports HDR for any screen
        // that could show it, the phone's included, so a TV with no EDR headroom is SDR here and an HDR
        // title is tone-mapped for it.
        let tv = GlassesCenter.live?.tvScreen
        let screen = tv ?? scene?.screen
        let traits = tv?.traitCollection ?? scene?.traitCollection
        return HardwareCapabilities.Display(
            hdrPlaybackEligible: AVPlayer.eligibleForHDRPlayback && (tv.map { $0.potentialEDRHeadroom > 1 } ?? true),
            edrHeadroomPotential: Double(screen?.potentialEDRHeadroom ?? 1),
            edrHeadroomCurrent: Double(screen?.currentEDRHeadroom ?? 1),
            maxFramesPerSecond: screen?.maximumFramesPerSecond ?? 60,
            wideGamut: traits?.displayGamut == .P3,
            capturing: traits?.sceneCaptureState == .active,
            externalPlaybackActive: externalPlaybackActive
        )
    }
}
