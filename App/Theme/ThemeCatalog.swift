import Foundation

/// The 40 themes bundled as themes.json, the same file check_themes.py proves in CI.
struct ThemeCatalog: Sendable {
    let dark: [Theme]
    let light: [Theme]
    let defaultDark: Theme
    let defaultLight: Theme

    static let bundled: ThemeCatalog = {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json") else {
            fatalError("themes.json is missing from the app bundle")
        }
        do {
            return try ThemeCatalog(data: Data(contentsOf: url))
        } catch {
            fatalError("themes.json did not load: \(error)")
        }
    }()

    /// themes.json names one default (the dark slot's); the light slot starts on its partner (DESIGN §5.2).
    private static let defaultLightID = "rose-pine-dawn"

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        let themes = file.themes.map { Theme(id: $0.id, name: $0.name, mode: $0.mode, roles: $0.colors) }
        let dark = themes.filter { $0.mode == .dark }
        let light = themes.filter { $0.mode == .light }
        guard let defaultDark = dark.first(where: { $0.id == file.default }) ?? dark.first,
              let defaultLight = light.first(where: { $0.id == Self.defaultLightID }) ?? light.first
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "themes.json needs at least one dark and one light theme"))
        }
        self.dark = dark
        self.light = light
        self.defaultDark = defaultDark
        self.defaultLight = defaultLight
    }

    func themes(for mode: ThemeMode) -> [Theme] {
        mode == .dark ? dark : light
    }

    /// The theme with `id` in `mode`; an id that no longer exists falls back to that mode's default.
    func theme(id: String?, mode: ThemeMode) -> Theme {
        themes(for: mode).first { $0.id == id } ?? (mode == .dark ? defaultDark : defaultLight)
    }

    private struct File: Decodable {
        let `default`: String
        let themes: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let mode: ThemeMode
        let colors: ThemeRoles
    }
}
