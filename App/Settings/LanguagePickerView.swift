import MarqueeCore
import SwiftUI

/// One language from the full list, searchable by name. `noneTitle` adds a first row that clears the
/// choice. A pick goes back at once.
struct LanguagePickerView: View {
    let title: String
    let noneTitle: String?
    @Binding var selection: TrackLanguage?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            Section {
                if let noneTitle, query.isEmpty {
                    row(noneTitle, isSelected: selection == nil) { selection = nil }
                }
                ForEach(matches, id: \.self) { language in
                    row(language.name ?? "", isSelected: selection?.matches(language) == true) { selection = language }
                }
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matches: [TrackLanguage] {
        guard !query.isEmpty else { return TrackLanguage.all }
        return TrackLanguage.all.filter { $0.name?.localizedStandardContains(query) == true }
    }

    private func row(_ name: String, isSelected: Bool, choose: @escaping @MainActor () -> Void) -> some View {
        Button {
            Haptics.selection()
            choose()
            dismiss()
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.accentText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("language.\(name)")
    }
}
