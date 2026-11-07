#if DEBUG
import AVFoundation
import UIKit

/// The UI tests' frame source. The simulator decodes no video, so a fixture picture
/// (`frames/player.jpg` in the fake Plex folder) stands in for it, paused where the test put it.
@MainActor
final class StillFrameBackend: VideoBackend {
    let image: UIImage?
    var player: AVPlayer? { nil }
    var onEvent: ((BackendEvent) -> Void)?
    private(set) var itemTime: TimeInterval = 0
    var itemDuration: TimeInterval? { nil }

    init(root: URL) {
        image = UIImage(contentsOfFile: root.appending(path: "frames/player.jpg").path(percentEncoded: false))
    }

    func load(_ item: AVPlayerItem?) {
        guard item != nil else { return }
        // Answered on the next turn, as AVPlayer would.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let image { onEvent?(.presentationSize(CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))) }
            onEvent?(.ready)
        }
    }

    func play() {
        onEvent?(.state(isPlaying: true, isBuffering: false))
    }

    func pause() {
        onEvent?(.state(isPlaying: false, isBuffering: false))
    }

    func seek(to itemTime: TimeInterval, precise: Bool) async -> Bool {
        self.itemTime = itemTime
        onEvent?(.time(itemTime))
        return true
    }

    func tearDown() {
        onEvent = nil
    }
}
#endif
