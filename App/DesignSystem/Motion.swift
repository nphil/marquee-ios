import SwiftUI

/// Motion tokens from DESIGN §9 that more than one screen uses.
enum Motion {
    /// Layout that moves: a card leaving a shelf, a section growing. Response 260 ms, critically damped; a
    /// 120 ms linear fade under Reduce Motion.
    static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.26, dampingFraction: 1)
    }

    /// A text or glyph swap, such as Play becoming Resume or a bookmark filling.
    static let label = Animation.easeInOut(duration: 0.12)

    /// A programmatic scroll (an A–Z jump): 300 ms at most, none under Reduce Motion.
    static func scroll(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    /// Hide on Scroll's tab bar sliding away or back: 300 ms, critically damped; under Reduce Motion it
    /// goes and comes without sliding.
    static func tabBar(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }
}
