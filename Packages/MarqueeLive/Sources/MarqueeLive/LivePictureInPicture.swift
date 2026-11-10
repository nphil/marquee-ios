import AVFoundation
import AVKit
import UIKit

/// Picture in Picture for the live picture. The window shows a live stream, without a scrubber; its pause holds the
/// picture while the stream goes on into the buffer, its play plays on (or opens the stream again after it ended), and
/// skips are ignored. It starts on its own when the app goes to the background while the picture is on screen.
@MainActor
public final class LivePictureInPicture: NSObject {
    /// Reopens the player screen, then calls the completion once it is on screen. Without it the window hands back
    /// to the screen that is still there.
    public var onRestore: ((@escaping @Sendable (Bool) -> Void) -> Void)?
    public private(set) var isActive = false

    private weak var player: LiveStreamPlayer?
    private var controller: AVPictureInPictureController?
    private var restoring = false

    init(player: LiveStreamPlayer) {
        self.player = player
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: player.view.displayLayer, playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
    }

    public var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    public func start() {
        controller?.startPictureInPicture()
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    /// The stream started or stopped: the window's play button follows.
    func playbackChanged() {
        controller?.invalidatePlaybackState()
    }

    private func setActive(_ active: Bool) {
        isActive = active
        player?.isPictureInPictureActive = active
    }
}

extension LivePictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            player?.resume()
        } else {
            player?.pause()
        }
    }

    /// An infinite range tells the system the stream is live.
    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        player.map { $0.isStopped || $0.isPaused } ?? true
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}

extension LivePictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    /// Set before the window appears, so going to the background keeps the pictures coming.
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        setActive(true)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        setActive(false)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        restoring = true
        if let onRestore {
            onRestore(completionHandler)
        } else {
            completionHandler(true)
        }
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        setActive(false)
        let restored = restoring
        restoring = false
        // Closing the window while the app is away frees the tuner.
        if !restored, player?.isInBackground == true { player?.close() }
    }
}
