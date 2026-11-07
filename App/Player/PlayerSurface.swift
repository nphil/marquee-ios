import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// A view backed by an AVPlayerLayer. The model keeps one for the whole playback, so Picture in Picture
/// carries on while the player screen is closed.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Puts the model's player layer view on screen, and takes it back after Picture in Picture.
struct VideoSurface: UIViewRepresentable {
    let view: PlayerLayerView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        host(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if view.superview !== container { host(in: container) }
    }

    private func host(in container: UIView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

/// Picture in Picture for the custom player layer. Starting it closes the player screen; the restore
/// button reopens it; closing the window ends playback.
@MainActor
final class PictureInPicture: NSObject {
    var onStart: (() -> Void)?
    /// Reopens the player, then calls the completion once it is on screen.
    var onRestore: ((@escaping @Sendable (Bool) -> Void) -> Void)?
    /// The window was closed without returning to the app's player.
    var onClose: (() -> Void)?
    var onPossibleChange: ((Bool) -> Void)?

    private(set) var isActive = false
    private let controller: AVPictureInPictureController?
    private var restoring = false
    private var possible: NSKeyValueObservation?

    init(layer: AVPlayerLayer) {
        controller = AVPictureInPictureController.isPictureInPictureSupported() ? AVPictureInPictureController(playerLayer: layer) : nil
        super.init()
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        possible = controller?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.possibleChanged() }
        }
    }

    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    func start() {
        controller?.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func tearDown() {
        possible?.invalidate()
        possible = nil
        onStart = nil
        onRestore = nil
        onClose = nil
        onPossibleChange = nil
        if isActive { controller?.stopPictureInPicture() }
    }

    private func possibleChanged() {
        onPossibleChange?(isPossible)
    }
}

extension PictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    /// Set before the window appears, so going to the background keeps the layer's player attached.
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
        onStart?()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        restoring = true
        if let onRestore {
            onRestore(completionHandler)
        } else {
            completionHandler(false)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        let restored = restoring
        restoring = false
        if !restored { onClose?() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        isActive = false
    }
}
