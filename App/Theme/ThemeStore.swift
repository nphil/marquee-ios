import MarqueeCore
import SwiftUI
import Observation

/// The appearance choices: the theme (DESIGN §5.2), the header style, the tab bar's tabs and what it does
/// on scroll (DESIGN §7), and whether scroll bars show. Matching the system keeps one theme per mode and
/// follows the iPhone's appearance; with matching off one fixed mode shows. Saved in UserDefaults, so
/// launch arguments such as `-marquee.theme.dark noir` override them (the UI tests rely on that).
@Observable @MainActor
final class ThemeStore {
    private(set) var matchSystem: Bool
    private(set) var light: Theme
    private(set) var dark: Theme
    /// The mode on screen while `matchSystem` is off.
    private(set) var fixedMode: ThemeMode
    private(set) var headerStyle: HeaderStyle
    private(set) var tabBar: TabBarBehavior
    private(set) var tabLayout: TabLayout
    private(set) var showsScrollBars: Bool

    private enum Key {
        static let matchSystem = "marquee.theme.matchSystem"
        static let light = "marquee.theme.light"
        static let dark = "marquee.theme.dark"
        static let fixedMode = "marquee.theme.fixedMode"
        static let headerStyle = "marquee.headerStyle"
        static let tabBar = "marquee.tabBar"
        /// Name arrays, so a launch argument such as `-marquee.tabs '(home, library, search)'` can set them.
        static let tabOrder = "marquee.tabOrder"
        static let tabs = "marquee.tabs"
        static let scrollBars = "marquee.scrollBars"
    }

    init() {
        let defaults = UserDefaults.standard
        let catalog = ThemeCatalog.bundled
        matchSystem = defaults.object(forKey: Key.matchSystem) == nil || defaults.bool(forKey: Key.matchSystem)
        light = catalog.theme(id: defaults.string(forKey: Key.light), mode: .light)
        dark = catalog.theme(id: defaults.string(forKey: Key.dark), mode: .dark)
        fixedMode = defaults.string(forKey: Key.fixedMode).flatMap(ThemeMode.init(rawValue:)) ?? .dark
        headerStyle = defaults.string(forKey: Key.headerStyle).flatMap(HeaderStyle.init(rawValue:)) ?? .soft
        tabBar = defaults.string(forKey: Key.tabBar).flatMap(TabBarBehavior.init(rawValue:)) ?? .minimise
        tabLayout = defaults.stringArray(forKey: Key.tabs).map {
            TabLayout(savedOrder: defaults.stringArray(forKey: Key.tabOrder) ?? [], savedShown: $0)
        } ?? .standard
        showsScrollBars = defaults.object(forKey: Key.scrollBars) == nil || defaults.bool(forKey: Key.scrollBars)
    }

    /// The theme on screen when the iPhone's appearance is `systemScheme`.
    func theme(for systemScheme: ColorScheme) -> Theme {
        selected(for: matchSystem ? ThemeMode(systemScheme) : fixedMode)
    }

    /// The scheme a presentation forces: none while matching the iPhone, the theme's own otherwise. Each
    /// sheet applies it, because the modifier reaches only the nearest presentation.
    func presentationScheme(for theme: Theme) -> ColorScheme? {
        matchSystem ? nil : theme.mode.colorScheme
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

    func setHeaderStyle(_ style: HeaderStyle) {
        headerStyle = style
        save()
    }

    func setTabBar(_ behavior: TabBarBehavior) {
        tabBar = behavior
        save()
    }

    // These two save only their own keys, so a layout a UI test gives as a launch argument is not written
    // back for the tests after it when another choice saves.
    func setTabLayout(_ layout: TabLayout) {
        tabLayout = layout
        let defaults = UserDefaults.standard
        defaults.set(layout.order.map(\.rawValue), forKey: Key.tabOrder)
        defaults.set(layout.savedShown, forKey: Key.tabs)
    }

    func setShowsScrollBars(_ on: Bool) {
        showsScrollBars = on
        UserDefaults.standard.set(on, forKey: Key.scrollBars)
    }

    /// Back to the first-launch choice, after Delete All Local Data emptied the saved one.
    func reset() {
        let catalog = ThemeCatalog.bundled
        matchSystem = true
        light = catalog.theme(id: nil, mode: .light)
        dark = catalog.theme(id: nil, mode: .dark)
        fixedMode = .dark
        headerStyle = .soft
        tabBar = .minimise
        tabLayout = .standard
        showsScrollBars = true
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(matchSystem, forKey: Key.matchSystem)
        defaults.set(light.id, forKey: Key.light)
        defaults.set(dark.id, forKey: Key.dark)
        defaults.set(fixedMode.rawValue, forKey: Key.fixedMode)
        defaults.set(headerStyle.rawValue, forKey: Key.headerStyle)
        defaults.set(tabBar.rawValue, forKey: Key.tabBar)
    }
}
