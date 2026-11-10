#if DEBUG
import AVFoundation
import UIKit

/// The UI tests' frame source. The simulator decodes no video, so a fixture picture (the path in the
/// fake Plex folder given as `-marquee.uitest.frame`) stands in for it. Its clock reports time the way
/// AVPlayer's periodic observer does: every 0.1 s while playing, and once after a seek or a stop. With
/// `-marquee.uitest.stall` it never starts: playback waits on data for good, as on a dead link.
@MainActor
final class StillFrameBackend: VideoBackend {
    let image: UIImage?
    var player: AVPlayer? { nil }
    var onEvent: ((BackendEvent) -> Void)?
    private(set) var itemTime: TimeInterval = 0
    var itemDuration: TimeInterval? { nil }
    var rate: Float = 1
    private var clock: Task<Void, Never>?
    private let stalls = UserDefaults.standard.bool(forKey: "marquee.uitest.stall")

    init(root: URL) {
        let frame = UserDefaults.standard.string(forKey: "marquee.uitest.frame") ?? ""
        image = frame.isEmpty ? nil : UIImage(contentsOfFile: root.appending(path: frame).path(percentEncoded: false))
    }

    func load(_ item: AVPlayerItem?) {
        stopClock()
        itemTime = 0
        guard item != nil else { return }
        // Answered on the next turn, as AVPlayer would.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let image { onEvent?(.presentationSize(CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))) }
            onEvent?(.ready)
        }
    }

    func play() {
        guard clock == nil else { return }
        if stalls {
            onEvent?(.state(isPlaying: true, isBuffering: true))
            return
        }
        onEvent?(.state(isPlaying: true, isBuffering: false))
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                itemTime += 0.1 * Double(rate)
                onEvent?(.time(itemTime))
            }
        }
    }

    func pause() {
        stopClock()
        onEvent?(.state(isPlaying: false, isBuffering: false))
        onEvent?(.time(itemTime))
    }

    func seek(to itemTime: TimeInterval, precise: Bool) async -> Bool {
        self.itemTime = itemTime
        // The observer reports the jump on a later turn, after the seek's caller has moved on.
        Task { @MainActor [weak self] in
            guard let self else { return }
            onEvent?(.time(self.itemTime))
        }
        return true
    }

    var transfer: (bytes: Int64, seconds: TimeInterval)? { nil }
    var bufferedAhead: TimeInterval? { nil }

    // One stream only: Auto's moves restart at the playhead.
    func openStandby(_ item: AVPlayerItem) async -> Bool { false }
    func prerollStandby(at itemTime: TimeInterval) async -> AVPlayer? { nil }
    func armSwitch(at itemTime: TimeInterval) {}
    func switchToStandby() {}
    func discardStandby() {}

    func tearDown() {
        stopClock()
        onEvent = nil
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }
}
#endif
