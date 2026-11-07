import SwiftUI

/// The theme picker (DESIGN §8.7). Matching the system shows a Light and a Dark slot, each opening
/// its mode's grid; with matching off one grid shows under a Dark | Light switch.
struct AppearanceView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    /// The grid on show while matching is off; until the switch is used, the mode on screen.
    @State private var shownMode: ThemeMode?

    var body: some View {
        List {
            Section {
                Toggle("Match System Appearance", isOn: Binding(
                    get: { store.matchSystem },
                    set: { store.setMatchSystem($0, systemScheme: colorScheme) }
                ))
                .tint(theme.accent)
                .accessibilityIdentifier("appearance.matchSystem")
            } footer: {
                Text(store.matchSystem
                     ? "Marquee follows the iPhone's light or dark appearance, with a theme for each."
                     : "One theme, whatever the iPhone's appearance.")
            }
            .listRowBackground(theme.sheet)

            if store.matchSystem {
                Section {
                    ForEach(ThemeMode.allCases) { mode in
                        NavigationLink {
                            ThemeGridPage(mode: mode)
                        } label: {
                            SlotRow(mode: mode, theme: store.selected(for: mode))
                        }
                        .accessibilityIdentifier("appearance.\(mode.rawValue)")
                    }
                }
                .listRowBackground(theme.sheet)
            } else {
                Section {
                    Picker("Themes", selection: Binding(
                        get: { shownMode ?? store.fixedMode },
                        set: { shownMode = $0 }
                    )) {
                        Text("Dark").tag(ThemeMode.dark)
                        Text("Light").tag(ThemeMode.light)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearance.mode")
                    .listRowInsets(EdgeInsets())

                    ThemeGrid(mode: shownMode ?? store.fixedMode)
                        .listRowInsets(EdgeInsets(top: Space.s4, leading: 0, bottom: Space.s4, trailing: 0))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .themedList(theme)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A Light or Dark slot: a small preview, the mode and the theme it uses.
private struct SlotRow: View {
    let mode: ThemeMode
    let theme: Theme

    var body: some View {
        HStack(spacing: Space.s4) {
            ThemePreview(theme: theme, cornerRadius: Radius.control)
                .frame(width: 42)
                .padding(.vertical, Space.s2)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(mode.title)
                Text(theme.name)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One mode's 20 themes as a grid of tiles; a tap re-themes the app at once.
struct ThemeGrid: View {
    let mode: ThemeMode

    @Environment(ThemeStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Adaptive at minimum 104 pt (3 columns at 390 pt); 2, then 1, at the accessibility sizes so
    /// the names have room to wrap.
    private var columns: [GridItem] {
        if typeSize >= .accessibility3 {
            return [GridItem(.flexible(maximum: 240))]
        }
        if typeSize >= .accessibility1 {
            return Array(repeating: GridItem(.flexible(), spacing: Space.s4), count: 2)
        }
        return [GridItem(.adaptive(minimum: Size.gridMin), spacing: Space.s4)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: Space.s4) {
            ForEach(ThemeCatalog.bundled.themes(for: mode)) { theme in
                ThemeTile(theme: theme, isSelected: store.isSelected(theme)) {
                    Haptics.selection()
                    store.select(theme)
                }
            }
        }
    }
}

/// A mode's grid as its own page, reached from the Light and Dark slots.
struct ThemeGridPage: View {
    let mode: ThemeMode

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            ThemeGrid(mode: mode)
                .padding(Space.inset)
        }
        .background(theme.canvas)
        .navigationTitle(mode == .dark ? "Dark Themes" : "Light Themes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
