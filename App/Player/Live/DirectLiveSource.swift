import LiveEngine
import MarqueeCore
import MarqueeLive
import Observation
import UIKit
import VideoToolbox

/// Live TV read straight from the tuner (docs/LIVE-TV.md §2): `<device>/auto/v<number>` played on MarqueeLive's
/// sample-buffer player. The tuner's slates are ordinary pictures, so nothing covers the picture; the status label
/// speaks only while nothing of the new channel is on screen ("Tuning 7.1"; H.264 and HEVC stations come without a
/// slate).
///
/// A tune while another plays is a takeover by the same client: the tuner moves this phone's stream to the new
/// channel, and the old picture stays until the new one's first. A refusal (503, or 805 when the TV is in use) ends
/// the tune with the tuner's own sentence.
@MainActor @Observable
final class DirectLiveSource: LiveVideoSource, GainSink {
    let player = LiveStreamPlayer()
    private(set) var channel: LiveChannel?

    /// A tune failed, before its first picture or while it played. The router carries on through Plex after a
    /// network error, no data, an end, or a stream the phone cannot decode (§2.2 rule 8), but not after a tuner's
    /// refusal, since Plex would be refused the same way. It also asks a LumaTV whether another client took the tuner.
    @ObservationIgnored var onFailed: ((LiveChannel, LiveError) -> Void)?
    /// The name this phone gives a LumaTV tuner, so the tuner can tell it who took the stream.
    @ObservationIgnored var clientName = ""
    /// The sentence the tuner gives for a 503 (full, or the TV recording), when it gives one. A refusal it explains is
    /// not retried without the conversion.
    @ObservationIgnored var sharingRefusal: ((LiveChannel) async -> String?)?
    /// The conversion profiles the tuner publishes; nil when it publishes none.
    @ObservationIgnored var transcodeProfiles: ((LiveChannel) async -> [TunerTranscode.Profile]?)?
    /// What the current tune asked of the tuner, and the codec it got, for the `live.direct.transcode` line.
    @ObservationIgnored private var asked = TunerTranscode.Decision(profile: nil, reason: "not-luma", source: nil)
    @ObservationIgnored private var got = "?"
    @ObservationIgnored private var retried = false
    @ObservationIgnored private let transcode = TunerTranscode.shared

    init() {
        player.onStateChange = { [weak self] state in self?.stateChanged(state) }
        player.onShape = { [weak self] codec, height in self?.shaped(codec: codec, height: height) }
        PlaybackGain.shared.register(self)
    }

    /// The sound follows `PlaybackGain`, which stands in for a system volume the app cannot set.
    func apply(gain: Float) {
        player.volume = gain
    }

    var videoView: UIView { player.view }

    var state: LiveState { Self.liveState(player.state) }

    var status: String? {
        guard player.state == .opening, let channel else { return nil }
        return "Tuning \(channel.number)"
    }

    /// "2.1 direct · slate 0.72 s · picture 3.52 s · sound 4.86 s · MPEG-2 1280×720p · AC-3 5.1→2.0 · J 0.30 s · …"
    var diagnosticsLine: String? {
        guard let channel else { return nil }
        return "\(channel.number) direct · \(player.diagnostics.line)"
    }

    var timeshift: LiveTimeshift {
        LiveTimeshift(isPaused: player.isPaused, behindLive: player.behindLive, reach: player.reach)
    }

    func play(_ channel: LiveChannel) async {
        await play(channel, tappedAt: nil)
    }

    /// `tappedAt` is `tapClock` at the channel change, so the tune's timing line counts from the tap.
    func play(_ channel: LiveChannel, tappedAt: Double?) async {
        await play(channel, tappedAt: tappedAt, retried: false)
    }

    private func play(_ channel: LiveChannel, tappedAt: Double?, retried: Bool) async {
        self.channel = channel
        self.retried = retried
        got = "?"
        #if DEBUG
        if FakeTuner.isActive { return FakeTuner.play(on: player) }
        #endif
        let url = channel.device.streamURL(channel)
        guard channel.device.isLumaTV else {
            asked = TunerTranscode.Decision(profile: nil, reason: "not-luma", source: nil)
            return player.open(url, tappedAt: tappedAt)
        }
        let offer = await transcodeProfiles?(channel)
        guard self.channel?.id == channel.id else { return }
        asked = transcode.decide(
            isLuma: true, tuner: "\(channel.device.uri)", channel: channel.number, offer: offer, canDecode: Self.decodes
        )
        let named = TunerTakeover.naming(url, as: clientName)
        player.open(asked.profile.map { TunerTranscode.asking(named, $0) } ?? named, tappedAt: tappedAt)
    }

    static func tapClock() -> Double { LiveStreamPlayer.tapClock() }

    func pause() {
        player.pause()
    }

    func resume() {
        player.resume()
    }

    func seek(behindLive: Double) {
        player.seek(behindLive: behindLive)
    }

    func stop() {
        player.close()
    }

    private func stateChanged(_ state: LiveStreamPlayer.State) {
        if case .picture = state {
            Diag.event(.live, "direct.transcode", [
                "asked": profileName, "profile": profileName, "reason": asked.reason, "source": sourceText,
                "got": got, "fallback": retried ? "retried" : "none",
            ])
        }
        guard case .failed(let failure) = state, let channel else { return }
        var status: Int?
        if case .refused(let refusal) = failure { status = refusal.status }
        let noPicture = failure == .noPicture
        guard asked.asked, status == 400 || status == 503 || noPicture else {
            onFailed?(channel, Self.error(failure))
            return
        }
        // The tuner's own sentence for a 503 says whether the conversion had anything to do with it.
        Task { @MainActor in
            let explained = status == 503 ? await sharingRefusal?(channel) != nil : false
            guard self.channel?.id == channel.id, case .failed = player.state else { return }
            guard TunerTranscode.retriesWithoutTranscode(asked: true, status: status, noPicture: noPicture, sharingRefusal: explained) else {
                onFailed?(channel, Self.error(failure))
                return
            }
            transcode.decline(tuner: "\(channel.device.uri)")
            Diag.event(.live, "direct.transcode", [
                "asked": profileName, "profile": profileName, "reason": asked.reason, "source": sourceText,
                "got": "none", "fallback": "retried",
            ])
            await play(channel, tappedAt: nil, retried: true)
        }
    }

    private var profileName: String { asked.profile?.name ?? "none" }
    private var sourceText: String { asked.source.map(String.init) ?? "unknown" }

    /// A decoder here for a profile's `codec` (VideoToolbox: H.264 always, HEVC where the chip has it, at any size).
    private static func decodes(_ codec: String, _ height: Int?) -> Bool {
        switch codec {
        case "h264": true
        case "hevc": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        default: false
        }
    }

    private func shaped(codec: String, height: Int) {
        got = codec
        // Only a tune that did not limit the picture says how tall the station is.
        if asked.profile?.maxHeight == nil, let channel { transcode.noted(height: height, tuner: "\(channel.device.uri)", channel: channel.number) }
    }

    static func liveState(_ state: LiveStreamPlayer.State) -> LiveState {
        switch state {
        case .idle: .idle
        case .opening: .opening
        case .slate: .slate
        case .picture: .picture
        case .playing: .playing
        case .stalled: .stalled
        case .failed(let failure): .failed(error(failure))
        }
    }

    static func error(_ failure: LiveStreamPlayer.Failure) -> LiveError {
        switch failure {
        case .refused(let refusal) where refusal.isProtected: .protectedChannel
        // A bare 503 is the tuner's busy answer without its 805 code.
        case .refused(let refusal): .refused(code: refusal.code ?? (refusal.isBusy ? 805 : nil), message: refusal.text)
        case .noPicture: .noData
        case .lost(let message): .network(message)
        case .unreadable(let message): .unsupported(message)
        // LumaTuner ends a stream with a last slate when the TV takes its tuner or the signal goes.
        case .ended: .refused(code: nil, message: "The tuner ended the stream.")
        }
    }
}
