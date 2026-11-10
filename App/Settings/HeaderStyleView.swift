import MarqueeCore
import SwiftUI

/// Header Style (DESIGN §7.1): how the bar at the top meets the page scrolling under it.
struct HeaderStyleView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                Picker("Header Style", selection: Binding(
                    get: { store.headerStyle },
                    set: { store.setHeaderStyle($0) }
                )) {
                    ForEach(HeaderStyle.allCases) { style in
                        Text(style.name).tag(style)
                            .accessibilityIdentifier("appearance.header.\(style.rawValue)")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Soft fades the page out under the bar, Hard draws a line under it, Blur frosts it.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Header Style")
        .navigationBarTitleDisplayMode(.inline)
    }
}
