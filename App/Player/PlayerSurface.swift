import AVFoundation
import AVKit
import SwiftUI
import UIKit
import VideoEngine

/// A view backed by an AVPlayerLayer. The model keeps one for the whole playback, so Picture in Picture
/// carries on while the player screen is closed.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    /// The standby player's picture, drawn unseen above the playing one so that Auto quality's switch
    /// (docs/adaptive-playback.md) shows it at once.
    private var standbyLayer: AVPlayerLayer?
    private var coverTask: Task<Void, Never>?
    /// The picture enhancer drawing over the player layer, with the same frame and gravity
    /// (docs/DESIGN.md, Enhance picture). Below the subtitles and controls, which are SwiftUI views above this one.
    private(set) var enhancer: PictureEnhancer?
    private var gravityObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    /// An Enhance slider is being dragged: the picture shows plain on the left and enhanced on the right.
    private var splitsEnhance = false
    private let splitLine = CALayer()
    private let originalLabel = CATextLayer()
    private let enhancedLabel = CATextLayer()
    private var splitLayers: [CALayer] { [splitLine, originalLabel, enhancedLabel] }

    func setEnhancer(_ enhancer: PictureEnhancer?) {
        if enhancer == nil { splitsEnhance = false }
        guard enhancer !== self.enhancer else { return }
        self.enhancer?.layer.mask = nil
        self.enhancer?.layer.removeFromSuperlayer()
        self.enhancer = enhancer
        splitLayers.forEach { $0.removeFromSuperlayer() }
        gravityObservation = nil
        readyObservation = nil
        if let enhancer {
            layer.addSublayer(enhancer.layer)
            // The enhancer follows the player layer when its gravity changes and when its first picture
            // arrives, which is when `videoRect` becomes known; layout alone sees neither.
            gravityObservation = playerLayer.observe(\.videoGravity) { [weak self] _, _ in
                Task { @MainActor in self?.layoutEnhancer() }
            }
            readyObservation = playerLayer.observe(\.isReadyForDisplay) { [weak self] _, _ in
                Task { @MainActor in self?.layoutEnhancer() }
            }
            layoutEnhancer()
        }
    }

    /// Puts the enhancer's layer exactly over the picture the player layer draws. `videoRect` is that picture
    /// whatever the gravity, so Fit, Fill and the rest stay as they are with Enhance on; before the player has a
    /// picture, the bounds and the gravity stand in for it.
    func layoutEnhancer() {
        guard let enhancer else { return }
        let picture = playerLayer.isReadyForDisplay ? playerLayer.videoRect : .zero
        let usesPicture = picture.width > 0 && picture.height > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        enhancer.layer.frame = usesPicture ? picture : bounds
        // The picture rectangle already is the fitted or filled one: the buffer, which has the picture's own
        // shape, stretches to it.
        enhancer.layer.videoGravity = usesPicture ? .resize : playerLayer.videoGravity
        CATransaction.commit()
        let area = usesPicture ? picture.size : bounds.size
        let scale = traitCollection.displayScale
        enhancer.displaySize = CGSize(width: area.width * scale, height: area.height * scale)
        updateSplit()
    }

    /// While an Enhance slider is dragged the picture is split down the middle: the left half is the plain
    /// picture and the right half the enhanced one, so the effect of the slider can be judged as it moves. The
    /// enhancer's layer is masked to the right half, and the player's own picture shows through the left.
    func setEnhanceSplit(_ on: Bool) {
        guard on != splitsEnhance else { return }
        splitsEnhance = on
        updateSplit()
    }

    private func updateSplit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let enhancer, splitsEnhance else {
            enhancer?.layer.mask = nil
            splitLayers.forEach { $0.removeFromSuperlayer() }
            return
        }
        let picture = enhancer.layer.frame
        let mask = enhancer.layer.mask ?? CALayer()
        mask.backgroundColor = UIColor.white.cgColor
        mask.frame = CGRect(x: picture.width / 2, y: 0, width: picture.width / 2, height: picture.height)
        enhancer.layer.mask = mask

        let top = max(picture.minY, safeAreaInsets.top) + Space.s2
        splitLine.backgroundColor = UIColor.white.cgColor
        splitLine.shadowColor = UIColor.black.cgColor
        splitLine.shadowOpacity = 0.5
        splitLine.shadowRadius = 2
        splitLine.shadowOffset = .zero
        splitLine.frame = CGRect(x: picture.midX - 0.75, y: picture.minY, width: 1.5, height: picture.height)
        for (label, text, alignment) in [(originalLabel, "Original", CATextLayerAlignmentMode.right), (enhancedLabel, "Enhanced", .left)] {
            label.string = text
            label.alignmentMode = alignment
            label.fontSize = 13
            label.foregroundColor = UIColor.white.cgColor
            label.shadowColor = UIColor.black.cgColor
            label.shadowOpacity = 0.7
            label.shadowRadius = 2
            label.shadowOffset = .zero
            label.contentsScale = traitCollection.displayScale
            let width: CGFloat = 96
            label.frame = CGRect(x: alignment == .right ? picture.midX - Space.s2 - width : picture.midX + Space.s2, y: top, width: width, height: 18)
        }
        for layer in splitLayers where layer.superlayer == nil { self.layer.addSublayer(layer) }
    }

    func prepareStandby(_ player: AVPlayer) {
        discardStandby()
        let standby = AVPlayerLayer(player: player)
        standby.videoGravity = playerLayer.videoGravity
        standby.frame = bounds
        standby.opacity = 0
        layer.addSublayer(standby)
        standbyLayer = standby
    }

    /// Shows the standby player in place of the playing one. Its own layer covers the swap until this
    /// view's layer draws the new picture.
    func switchToStandby() {
        guard let standby = standbyLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        standby.opacity = 1
        playerLayer.player = standby.player
        CATransaction.commit()
        coverTask = Task { [weak self] in
            // The cover shows the same player, so staying a little long costs nothing.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if playerLayer.isReadyForDisplay { break }
            }
            self?.discardStandby()
        }
    }

    func discardStandby() {
        coverTask?.cancel()
        coverTask = nil
        standbyLayer?.removeFromSuperlayer()
        standbyLayer = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutEnhancer()
        guard let standbyLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        standbyLayer.frame = bounds
        CATransaction.commit()
    }
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
    /// The window opened or closed: AVPlayer draws the subtitles in it.
    var onActiveChange: ((Bool) -> Void)?

    private(set) var isActive = false {
        didSet { if isActive != oldValue { onActiveChange?(isActive) } }
    }
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
        onActiveChange = nil
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
