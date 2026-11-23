import MarqueeCore
import UIKit

extension ScreenClass {
    /// This device's class for HomeLabber's two scorings. The hardware decides, not the interface idiom: this app
    /// is iPhone-only, so on an iPad it runs in the compatibility window and reports the phone idiom.
    @MainActor static var current: ScreenClass {
        UIDevice.current.model.hasPrefix("iPad") ? .tablet : .phone
    }
}
