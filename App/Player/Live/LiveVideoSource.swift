import MarqueeCore
import UIKit

/// A live source with a picture. The player hosts `videoView` as it is and sets only how it fills the
/// screen (`videoGravity` of an AVPlayerLayer or AVSampleBufferDisplayLayer backing it).
@MainActor protocol LiveVideoSource: LiveSource { var videoView: UIView { get } }
