import SwiftUI
import UIKit

/// A colour as themes.json stores it: sRGB components and alpha, each 0–1.
struct RGBA: Equatable, Sendable, Decodable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, let raw = UInt32(digits, radix: 16) else { return nil }
        let value = digits.count == 6 ? raw << 8 | 0xFF : raw
        self.init(
            red: Double(value >> 24 & 0xFF) / 255,
            green: Double(value >> 16 & 0xFF) / 255,
            blue: Double(value >> 8 & 0xFF) / 255,
            alpha: Double(value & 0xFF) / 255
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let value = RGBA(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(hex) is not #RRGGBB or #RRGGBBAA")
        }
        self = value
    }

    func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// This colour laid over an opaque `base`: what the eye actually sees.
    func over(_ base: RGBA) -> RGBA {
        RGBA(
            red: red * alpha + base.red * (1 - alpha),
            green: green * alpha + base.green * (1 - alpha),
            blue: blue * alpha + base.blue * (1 - alpha),
            alpha: 1
        )
    }

    /// `fraction` of the way to `other`, mixed in sRGB as check_themes.py does.
    func mixed(toward other: RGBA, by fraction: Double) -> RGBA {
        RGBA(
            red: red + (other.red - red) * fraction,
            green: green + (other.green - green) * fraction,
            blue: blue + (other.blue - blue) * fraction,
            alpha: alpha + (other.alpha - alpha) * fraction
        )
    }

    /// WCAG 2 contrast ratio between two opaque colours.
    func contrast(with other: RGBA) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

/// Lucent's 20 colour roles, named as in themes.json (DESIGN §5.1).
struct ThemeRoles: Equatable, Sendable, Decodable {
    var canvas, sheet, scrim, glass, glassRaised, edge, edgeRaised: RGBA
    var ink, ink2, ink3, focus, focusInk, trackOff, accent, accentInk: RGBA
    var positive, warning, danger, info, live: RGBA
}

enum ThemeMode: String, CaseIterable, Identifiable, Sendable, Decodable {
    case light, dark

    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }

    var id: Self { self }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var title: String { self == .dark ? "Dark" : "Light" }
}

/// One theme, with its roles resolved to colours once so views never build them per frame.
struct Theme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mode: ThemeMode
    let roles: ThemeRoles

    let canvas: Color
    let sheet: Color
    let scrim: Color
    let glass: Color
    let glassRaised: Color
    let edge: Color
    let edgeRaised: Color
    let ink: Color
    let ink2: Color
    let ink3: Color
    let focus: Color
    let focusInk: Color
    let trackOff: Color
    let accent: Color
    let accentInk: Color
    let positive: Color
    let warning: Color
    let danger: Color
    let info: Color
    let live: Color
    /// The accent where it is text (tab labels, links, text buttons); fills and large glyphs use `accent`.
    let accentText: Color

    init(id: String, name: String, mode: ThemeMode, roles: ThemeRoles) {
        self.id = id
        self.name = name
        self.mode = mode
        self.roles = roles
        canvas = roles.canvas.color
        sheet = roles.sheet.color
        scrim = roles.scrim.color
        glass = roles.glass.color
        glassRaised = roles.glassRaised.color
        edge = roles.edge.color
        edgeRaised = roles.edgeRaised.color
        ink = roles.ink.color
        ink2 = roles.ink2.color
        ink3 = roles.ink3.color
        focus = roles.focus.color
        focusInk = roles.focusInk.color
        trackOff = roles.trackOff.color
        accent = roles.accent.color
        accentInk = roles.accentInk.color
        positive = roles.positive.color
        warning = roles.warning.color
        danger = roles.danger.color
        info = roles.info.color
        live = roles.live.color
        accentText = Self.accentText(roles).color
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.id == rhs.id && lhs.roles == rhs.roles
    }

    /// The theme under the iPhone's Increase Contrast and Reduce Transparency settings (DESIGN §5.3):
    /// translucent fills become opaque composites over canvas; Increase Contrast also promotes ink2 to
    /// ink and raises the edges to 3:1. No extra palettes.
    func adjusted(increaseContrast: Bool, reduceTransparency: Bool) -> Theme {
        guard increaseContrast || reduceTransparency else { return self }
        var adjusted = roles
        adjusted.sheet = roles.sheet.over(roles.canvas)
        adjusted.glass = roles.glass.over(roles.canvas)
        adjusted.glassRaised = roles.glassRaised.over(roles.canvas)
        if increaseContrast {
            adjusted.ink2 = roles.ink
            adjusted.edge = Self.rim(roles.edge, roles: roles)
            adjusted.edgeRaised = Self.rim(roles.edgeRaised, roles: roles)
        }
        return Theme(id: id, name: name, mode: mode, roles: adjusted)
    }

    /// The accent itself when it reads at 4.5:1 on canvas, otherwise mixed toward ink in 5% steps
    /// until it does. Only Rosé Pine Dawn needs the mix (#907AA9 becomes #78658D).
    private static func accentText(_ roles: ThemeRoles) -> RGBA {
        for step in 0...20 {
            let candidate = roles.accent.mixed(toward: roles.ink, by: Double(step) * 0.05)
            if candidate.over(roles.canvas).contrast(with: roles.canvas) >= 4.5 { return candidate }
        }
        return roles.ink
    }

    /// An edge raised to 3:1 on canvas: its own colour at a higher alpha where that gets there (the
    /// dark themes' white rims), otherwise an ink rim (a white rim on a light canvas never reaches 3:1).
    private static func rim(_ edge: RGBA, roles: ThemeRoles) -> RGBA {
        raised(edge, on: roles.canvas) ?? raised(roles.ink.withAlpha(0), on: roles.canvas) ?? roles.ink
    }

    private static func raised(_ colour: RGBA, on canvas: RGBA) -> RGBA? {
        for step in 0...20 {
            let candidate = colour.withAlpha(min(1, colour.alpha + Double(step) * 0.05))
            if candidate.over(canvas).contrast(with: canvas) >= 3 { return candidate }
        }
        return nil
    }
}

extension EnvironmentValues {
    /// The theme every view draws with, already adjusted for the accessibility settings.
    @Entry var theme: Theme = ThemeCatalog.bundled.defaultDark
}
