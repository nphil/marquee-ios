import MarqueeCore
import SwiftUI

/// Tab Bar (DESIGN §7, §8.7): which places are tabs, dragged into the bar's order, and what the bar does
/// while a page scrolls. Each place names its way in for when it is not a tab.
struct TabBarView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = store.tabLayout
        let available = Destination.available(in: session)
        let tabs = layout.tabs(available: available)
        // Search keeps the last place, so it sits below the rows that move.
        let movable = layout.order.filter { $0 != .search }
        List {
            Section {
                ForEach(Array(movable.enumerated()), id: \.element) { index, destination in
                    toggle(destination, layout: layout, available: available, tabs: tabs)
                        .accessibilityActions {
                            if index > 0 {
                                Button("Move Up") { move(movable, from: index, to: index - 1) }
                            }
                            if index < movable.count - 1 {
                                Button("Move Down") { move(movable, from: index, to: index + 2) }
                            }
                        }
                }
                .onMove { source, offset in
                    var order = movable
                    order.move(fromOffsets: source, toOffset: offset)
                    // The list has already drawn the drop; animating again would replay it.
                    var edited = store.tabLayout
                    edited.reorder(order)
                    store.setTabLayout(edited)
                }
                toggle(.search, layout: layout, available: available, tabs: tabs)
            } header: {
                Text("Tabs")
            } footer: {
                Text("Up to five tabs, in this order. Home stays a tab, as its profile button opens Settings, and Search stays last.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Picker("On Scroll", selection: Binding(
                    get: { store.tabBar },
                    set: { store.setTabBar($0) }
                )) {
                    ForEach(TabBarBehavior.allCases) { behavior in
                        Text(behavior.name).tag(behavior)
                            .accessibilityIdentifier("appearance.tabBar.\(behavior.rawValue)")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("On Scroll")
            } footer: {
                Text("While a page scrolls down, Hide on Scroll slides the tab bar away and Minimise on Scroll shrinks it to the current tab. Scrolling back up or reaching the top brings it back.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        // Always editing, so every movable row shows its drag handle.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Bar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ destination: Destination, layout: TabLayout, available: Set<Destination>, tabs: [Destination]) -> some View {
        TabToggle(
            destination: destination,
            note: note(destination, available: available.contains(destination)),
            isOn: Binding(
                get: { tabs.contains(destination) },
                set: { on in
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                        var edited = store.tabLayout
                        edited.setTab(destination, on, available: available)
                        store.setTabLayout(edited)
                    }
                }
            )
        )
        .disabled(!layout.canSwitch(destination, available: available))
    }

    private func move(_ order: [Destination], from index: Int, to offset: Int) {
        var order = order
        order.move(fromOffsets: [index], toOffset: offset)
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            var edited = store.tabLayout
            edited.reorder(order)
            store.setTabLayout(edited)
        }
    }

    /// Where the place opens from when it is not a tab (DESIGN §7).
    private func note(_ destination: Destination, available: Bool) -> String {
        guard available else { return "Needs Seerr, set up in Settings." }
        return switch destination {
        case .home: "Always a tab."
        case .library: "Otherwise in Home's title menu."
        case .liveTV: "Otherwise in the Library's title menu."
        case .watchlist: "Otherwise a row on Home and in the Library's title menu."
        case .search: "Otherwise a button at the top of the Library."
        case .requests: "Otherwise the + button at the top of the Library."
        case .downloads: "Otherwise in the Library's title menu and Settings."
        }
    }
}

/// One place on the Tab Bar page: its tab icon, its name, where it opens from otherwise, and its switch.
private struct TabToggle: View {
    let destination: Destination
    let note: String
    @Binding var isOn: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text(destination.title)
                        .textRole(.body)
                        .foregroundStyle(theme.ink)
                    Text(note)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                }
                .padding(.vertical, Space.s1)
            } icon: {
                Image(systemName: destination.systemImage)
                    .foregroundStyle(theme.accentText)
            }
        }
        .tint(theme.accent)
        .accessibilityIdentifier("tabBar.\(destination.rawValue)")
    }
}
