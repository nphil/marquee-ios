import AVFoundation
import OSLog
import UIKit

/// Keeps the app running in the background while downloads remain, so the transfer in the app goes on
/// after it leaves the screen.
///
/// A `beginBackgroundTask` assertion cannot be extended, but an app with the `audio` background mode
/// and an active audio session may end its assertion and be given a fresh one, again and again. iOS's
/// window is per app, so it only starts over when nothing else is outstanding: the download holds no
/// assertion of its own while this runs. Each cycle plays an inaudible tone, swaps the assertion and
/// pauses, then waits 10 s. Ported from Stashy, where it held 290 s of background runtime and 725 MB
/// on its first device run (2026-07-26). Apple documents none of this, so an iOS update can end it
/// without a sound: the log to check is `dl-keepalive tick=` climbing past 30 s while the file grows.
@MainActor
final class DownloadKeepAlive {
    /// True while the pump owns the app's background window.
    private(set) var isRunning = false
    /// Called when the pump gives up while work remains, so the download can hand itself over.
    var onSurrender: (@MainActor () -> Void)?

    private let log = Logger(subsystem: "com.nphil.marquee", category: "downloads")
    private var player: AVAudioPlayer?
    private var pump: Task<Void, Never>?
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    /// Keeps a late expiry of an ended assertion from clearing the current one.
    private var assertionGeneration = 0
    private var interruption: (any NSObjectProtocol)?
    private var stillNeeded: (@MainActor () -> Bool)?
    private var ticks = 0
    private var refusals = 0
    private var startedAt = Date.now

    /// Pumps for as long as `needed()` holds; it is asked again at the top of every cycle, so the end
    /// of the work stops the pump without anyone watching for it.
    func start(while needed: @escaping @MainActor () -> Bool) {
        guard !isRunning, needed() else { return }
        guard let tone = Self.toneURL() else {
            log.error("dl-keepalive start=no-tone")
            return
        }
        isRunning = true
        stillNeeded = needed
        ticks = 0
        refusals = 0
        startedAt = .now
        observeInterruptions()
        log.notice("dl-keepalive start")
        pump = Task { await run(tone: tone) }
    }

    /// `restoringCategory`: give the session back the player's category, unless another app is
    /// playing. Left mixing, a playback that outlived the trip would mix for the rest of its life;
    /// restored while music plays, the music would stop.
    func stop(restoringCategory: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        pump?.cancel()
        pump = nil
        stillNeeded = nil
        player?.stop()
        player = nil
        endAssertion()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        let session = AVAudioSession.sharedInstance()
        var restored = false
        if restoringCategory, !session.isOtherAudioPlaying {
            try? session.setCategory(.playback, mode: .moviePlayback)
            restored = true
        }
        let up = Int(Date.now.timeIntervalSince(startedAt))
        log.notice("dl-keepalive stop ticks=\(self.ticks, privacy: .public) up=\(up, privacy: .public) restored=\(restored, privacy: .public)")
    }

    // MARK: The pump

    private func run(tone: URL) async {
        // `setActive` blocks while the system settles audio with other apps; iOS 27 warns when that
        // happens on the main thread.
        let active = await Task.detached { Self.activateMixingSession() }.value
        guard !Task.isCancelled, isRunning else { return }
        guard active, let player = try? AVAudioPlayer(contentsOf: tone) else {
            log.error("dl-keepalive start=session-failed")
            surrender()
            return
        }
        player.volume = 0.01
        player.numberOfLoops = -1
        player.prepareToPlay()
        self.player = player
        while !Task.isCancelled {
            guard isRunning, stillNeeded?() == true else {
                stop()
                return
            }
            // A few frames of real output before the swap, as iTorrent does.
            player.play()
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, isRunning else { return }
            endAssertion()
            beginAssertion()
            player.pause()
            if assertion == .invalid {
                // Three refusals in a row: the technique is not working here.
                refusals += 1
                log.notice("dl-keepalive refused=\(self.refusals, privacy: .public)")
                guard refusals < 3 else {
                    surrender()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            refusals = 0
            ticks += 1
            let up = Int(Date.now.timeIntervalSince(startedAt))
            log.notice("dl-keepalive tick=\(self.ticks, privacy: .public) up=\(up, privacy: .public)")
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }

    /// Mixing, so a download in the background never silences the owner's music.
    private nonisolated static func activateMixingSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    /// Gives up while work remains, unlike `stop()`, which means nothing is left to do.
    private func surrender() {
        log.notice("dl-keepalive surrender ticks=\(self.ticks, privacy: .public)")
        let handBack = onSurrender
        stop()
        handBack?()
    }

    private func beginAssertion() {
        assertionGeneration += 1
        let generation = assertionGeneration
        assertion = UIApplication.shared.beginBackgroundTask(withName: "marquee-keepalive") { [weak self] in
            // iOS ends the app unless the assertion ends before this handler returns.
            MainActor.assumeIsolated { self?.expire(generation) }
        }
    }

    private func expire(_ generation: Int) {
        guard generation == assertionGeneration else { return }
        log.notice("dl-keepalive expired=\(generation, privacy: .public)")
        endAssertion()
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    // MARK: Interruptions

    /// A call or another app deactivates the session and stops the tone, and iOS does not hand it
    /// back. Claiming it again on any interruption fails harmlessly while it begins and works when it
    /// ends.
    private func observeInterruptions() {
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaim() }
        }
    }

    private func reclaim() {
        guard isRunning else { return }
        let reclaimed = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
        if reclaimed, player?.isPlaying == false { player?.play() }
        log.notice("dl-keepalive interrupt=\(reclaimed ? "reclaimed" : "held", privacy: .public)")
    }

    // MARK: The tone

    /// Made on first use rather than bundled, so a missing resource cannot quietly turn this off.
    private static func toneURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "marquee-keepalive.wav")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1024 { return url }
        do {
            try tone().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 0.5 s of 16-bit mono 44.1 kHz PCM at about −60 dBFS, played at volume 0.01: inaudible, yet real
    /// samples rather than digital silence, which iTorrent moved away from. 400 Hz fits 200 whole
    /// cycles into the clip, so the loop has no seam to click on.
    static func tone() -> Data {
        let rate = 44_100
        let frames = rate / 2
        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value = sin(2 * Double.pi * 400 * Double(frame) / Double(rate)) * 32
            withUnsafeBytes(of: Int16(value.rounded()).littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data(capacity: samples.count + 44)
        func ascii(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        ascii("RIFF")
        u32(UInt32(36 + samples.count))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1) // PCM
        u16(1) // mono
        u32(UInt32(rate))
        u32(UInt32(rate * 2)) // bytes per second
        u16(2) // bytes per frame
        u16(16) // bits per sample
        ascii("data")
        u32(UInt32(samples.count))
        wav.append(samples)
        return wav
    }
}
