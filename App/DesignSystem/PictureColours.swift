import SwiftUI

/// Colours that belong to the picture rather than the theme (DESIGN §5.4, "Over video"): the black
/// behind video, a bright frame for checking legibility, and the subtitle colours a profile picks.
/// They stay the same in every theme.
enum PictureColours {
    static let black = Color.black
    static let bright = Color(white: 0.86)
    /// Behind subtitles when the style asks for a background box.
    static let subtitleBox = Color.black.opacity(0.75)
    /// Subtitle outlines and drop shadows.
    static let subtitleEdge = Color.black

    static func subtitle(_ colour: SubtitleStyle.Colour) -> Color {
        switch colour {
        case .white: .white
        case .yellow: Color(red: 1, green: 0.9, blue: 0.3)
        case .cyan: Color(red: 0.45, green: 1, blue: 1)
        }
    }
}
