import SwiftUI
import MarqueeCore

struct RecordingEditor: View {
    @State var draft: RecordingDraft
    let save: (RecordingSubmission) async throws -> Void
    var remove: (() async throws -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirmsDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section("Record") {
                    ForEach(draft.scopes) { choice in
                        Button { draft.choose(scope: choice.scope) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(choice.title).textRole(.headline)
                                    Text(choice.detail).textRole(.label).foregroundStyle(theme.ink2)
                                }
                                Spacer()
                                Image(systemName: draft.scope == choice.scope ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .accessibilityIdentifier("record.scope.\(choice.scope.rawValue)")
                    }
                }.listRowBackground(theme.sheet)
                Section {
                    ForEach(draft.rows) { row in
                        VStack(alignment: .leading) {
                            switch row.control {
                            case .toggle(let on):
                                Toggle(row.title, isOn: Binding(get: { on }, set: { draft.set(row.id, on: $0) }))
                            case .menu(let selected):
                                Picker(row.title, selection: Binding(get: { selected }, set: { draft.choose(row.id, $0) })) {
                                    ForEach(row.choices) { Text($0.label).tag($0.id) }
                                }
                            }
                            if let note = row.note { Text(note).textRole(.caption).foregroundStyle(theme.ink2) }
                        }
                    }
                } footer: { Text(draft.summary).accessibilityIdentifier("record.summary") }
                .listRowBackground(theme.sheet)
                if let errorMessage { Text(errorMessage).foregroundStyle(theme.danger) }
                if remove != nil {
                    Button("Delete Rule", role: .destructive) { confirmsDelete = true }
                        .accessibilityIdentifier("livetv.rule.delete")
                }
            }
            .themedList(theme)
            .navigationTitle(draft.subject.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("livetv.rule.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.editing == nil ? "Record" : "Save") {
                        guard let submission = draft.submission else { return }
                        perform { try await save(submission) }
                    }.disabled(!draft.isChanged || draft.submission == nil)
                }
            }
            .disabled(busy).interactiveDismissDisabled(busy)
            .confirmationDialog("Delete this rule? Existing recordings stay in the library.", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Rule", role: .destructive) { if let remove { perform(remove) } }
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); dismiss() } catch { errorMessage = error.localizedDescription }
        }
    }
}
