import MarqueeCore
import SwiftUI

/// Colours that belong to the picture rather than the theme (DESIGN §5.4, "Over video"): the black
/// behind video, a bright frame for checking legibility, and the subtitle colours a profile picks.
/// They stay the same in every theme.
enum PictureColours {
    typealias RGB = (red: Double, green: Double, blue: Double)

    static let black = Color.black
    static let bright = Color(white: 0.86)
    /// Subtitle outlines and shadows.
    static let subtitleEdge = Color.black
    /// The lit side of a raised or depressed subtitle edge.
    static let subtitleHighlight = Color(white: 0.8)

    static func subtitle(_ look: SubtitleLook) -> Color {
        color(subtitleRGB(look))
    }

    static func subtitleBox(_ colour: SubtitleLook.BoxColour) -> Color {
        color(rgb(colour))
    }

    /// The text colour as drawn. Blend with video holds it just under full brightness, so a subtitle never
    /// reads as the brightest thing in a dark scene.
    static func subtitleRGB(_ look: SubtitleLook) -> RGB {
        let base = rgb(look.colour)
        guard look.blendsWithVideo else { return base }
        func soften(_ value: Double) -> Double { value * 0.88 + 0.06 }
        return (soften(base.red), soften(base.green), soften(base.blue))
    }

    static func rgb(_ colour: SubtitleLook.BoxColour) -> RGB {
        switch colour {
        case .black: (0, 0, 0)
        case .plum: (0.24, 0.1, 0.24)
        case .slate: (0.15, 0.19, 0.25)
        case .brown: (0.24, 0.15, 0.09)
        }
    }

    private static func rgb(_ colour: SubtitleLook.TextColour) -> RGB {
        switch colour {
        case .white: (1, 1, 1)
        case .softWhite: (0.88, 0.88, 0.88)
        case .yellow: (1, 0.9, 0.3)
        case .cyan: (0.45, 1, 1)
        case .green: (0.5, 0.95, 0.5)
        case .pink: (1, 0.62, 0.84)
        }
    }

    private static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
