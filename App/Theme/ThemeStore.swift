import SwiftUI
import Observation

/// The theme choice (DESIGN §5.2). Matching the system keeps one theme per mode and follows the
/// iPhone's appearance; with matching off one fixed mode shows. Saved in UserDefaults, so launch
/// arguments such as `-marquee.theme.dark noir` override it (the UI tests rely on that).
@Observable @MainActor
final class ThemeStore {
    private(set) var matchSystem: Bool
    private(set) var light: Theme
    private(set) var dark: Theme
    /// The mode on screen while `matchSystem` is off.
    private(set) var fixedMode: ThemeMode

    private enum Key {
        static let matchSystem = "marquee.theme.matchSystem"
        static let light = "marquee.theme.light"
        static let dark = "marquee.theme.dark"
        static let fixedMode = "marquee.theme.fixedMode"
    }

    init() {
        let defaults = UserDefaults.standard
        let catalog = ThemeCatalog.bundled
        matchSystem = defaults.object(forKey: Key.matchSystem) == nil || defaults.bool(forKey: Key.matchSystem)
        light = catalog.theme(id: defaults.string(forKey: Key.light), mode: .light)
        dark = catalog.theme(id: defaults.string(forKey: Key.dark), mode: .dark)
        fixedMode = defaults.string(forKey: Key.fixedMode).flatMap(ThemeMode.init(rawValue:)) ?? .dark
    }

    /// The theme on screen when the iPhone's appearance is `systemScheme`.
    func theme(for systemScheme: ColorScheme) -> Theme {
        selected(for: matchSystem ? ThemeMode(systemScheme) : fixedMode)
    }

    func selected(for mode: ThemeMode) -> Theme {
        mode == .dark ? dark : light
    }

    /// Whether the picker marks `theme`: it fills its mode's slot and, with matching off, that mode shows.
    func isSelected(_ theme: Theme) -> Bool {
        selected(for: theme.mode).id == theme.id && (matchSystem || theme.mode == fixedMode)
    }

    /// Fills the theme's mode slot; with matching off that mode also becomes the one on screen.
    func select(_ theme: Theme) {
        if theme.mode == .dark { dark = theme } else { light = theme }
        if !matchSystem { fixedMode = theme.mode }
        save()
    }

    /// Turning matching off keeps the current appearance as the fixed mode, so the toggle alone
    /// changes nothing on screen.
    func setMatchSystem(_ on: Bool, systemScheme: ColorScheme) {
        if !on { fixedMode = ThemeMode(systemScheme) }
        matchSystem = on
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(matchSystem, forKey: Key.matchSystem)
        defaults.set(light.id, forKey: Key.light)
        defaults.set(dark.id, forKey: Key.dark)
        defaults.set(fixedMode.rawValue, forKey: Key.fixedMode)
    }
}
