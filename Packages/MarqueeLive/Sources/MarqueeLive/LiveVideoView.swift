import AVFoundation
import UIKit

/// The view a live stream draws on: its layer is the sample-buffer display layer. Hosts set only how the picture
/// fills it (`displayLayer.videoGravity`).
public final class LiveVideoView: UIView {
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    public var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
