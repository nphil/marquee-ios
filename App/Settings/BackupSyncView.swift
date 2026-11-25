import MarqueeCore
import SwiftUI

/// Backup & Sync (DESIGN §8.13): a backup file saved anywhere in Files and restored from there, a folder in
/// Files that keeps one up to date, and the recovery passphrase that opens a backup where the account's key
/// is not. Nothing here shows a value: the sheets and lines carry counts, dates and names of settings only.
struct BackupSyncView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var store
    @State private var choosingBackup = false
    @State private var editingPassphrase = false
    @State private var confirmsRemoval = false

    var body: some View {
        let center = session.backup
        List {
            backUp(center)
            automatic(center)
            recovery(center)
        }
        .themedList(theme)
        .navigationTitle("Backup & Sync")
        .navigationBarTitleDisplayMode(.inline)
        .background { pickers(center) }
        .sheet(isPresented: $editingPassphrase) {
            PassphraseSheet()
                .preferredColorScheme(store.presentationScheme(for: theme))
        }
        .sheet(item: Binding(get: { center.restoreFlow }, set: { if $0 == nil { center.closeRestore() } })) { _ in
            RestoreSheet()
                .preferredColorScheme(store.presentationScheme(for: theme))
        }
        .onAppear {
            center.pageIsOpen = true
            center.refresh()
            center.takePendingOpen()
        }
        .onDisappear { center.pageIsOpen = false }
        .onChange(of: center.pendingOpen) { center.takePendingOpen() }
    }

    // MARK: Back up

    private func backUp(_ center: BackupCenter) -> some View {
        let enabled = center.account != nil && center.activity == .idle
        return Section {
            Button {
                center.backUpNow()
            } label: {
                HStack {
                    Text("Back Up Now")
                    Spacer()
                    if center.activity != .idle { ProgressView() }
                }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("backup.now")
            Button("Restore from Backup…") { choosingBackup = true }
                .disabled(!enabled)
                .accessibilityIdentifier("backup.restore")
            LabeledContent("Last Backup") {
                Text(center.lastBackup?.stamp ?? "Never")
                    .foregroundStyle(theme.ink2)
            }
            .accessibilityIdentifier("backup.last")
        } footer: {
            if let problem = center.problem {
                ProblemLine(text: problem)
                    .accessibilityIdentifier("backup.problem")
            } else if center.account == nil {
                Text(BackupError.noAccount.message)
                    .foregroundStyle(theme.ink2)
            } else {
                Text("One encrypted file with the settings, themes, tab layout, integrations and their keys, and paired TVs. The Plex sign-in, downloads and caches are not in it. It can be saved anywhere Files reaches: iCloud Drive, a network share, Google Drive.")
                    .foregroundStyle(theme.ink2)
            }
        }
        .listRowBackground(theme.sheet)
    }

    // MARK: Automatic

    private func automatic(_ center: BackupCenter) -> some View {
        Group {
            Section {
                Toggle("Automatic Backup", isOn: Binding(get: { center.automaticIsOn }, set: { setAutomatic($0, center) }))
                    .disabled(center.account == nil || center.activity != .idle)
                    .accessibilityIdentifier("backup.auto")
                if let name = center.folderName {
                    LabeledContent("Folder") {
                        Text(name).foregroundStyle(theme.ink2)
                    }
                    LabeledContent("Last Saved") {
                        Text(center.lastAutomatic?.stamp ?? "Not yet").foregroundStyle(theme.ink2)
                    }
                    .accessibilityIdentifier("backup.auto.last")
                    Button("Choose Another Folder…") { FolderPicker.present { center.chooseFolder($0) } }
                        .accessibilityIdentifier("backup.folder")
                }
            } footer: {
                if let problem = center.automaticProblem {
                    ProblemLine(text: problem)
                        .accessibilityIdentifier("backup.auto.problem")
                } else if center.automaticIsOn {
                    Text("The backup in the folder is replaced a short while after a setting changes. The copy before it stays beside it as “\(BackupFiles.previousName)”.")
                        .foregroundStyle(theme.ink2)
                } else {
                    Text("Keeps one backup up to date in a folder chosen in Files. A folder in iCloud Drive keeps it in iCloud, ready to restore on a new iPhone.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            if let date = center.foundNewer {
                Section {
                    Button("Restore That Backup") { center.restoreFromFolder() }
                        .accessibilityIdentifier("backup.newer.restore")
                    Button("Replace It with This iPhone's Settings") { center.replaceNewerInFolder() }
                        .accessibilityIdentifier("backup.newer.replace")
                } footer: {
                    StatusLine(
                        symbol: "icloud.and.arrow.down", tint: theme.accentText,
                        text: "The folder holds a backup from \(date.stamp), newer than anything this iPhone saved. Automatic backup waits until one of these is chosen."
                    )
                    .accessibilityIdentifier("backup.newer")
                }
                .listRowBackground(theme.sheet)
            }
        }
    }

    private func setAutomatic(_ on: Bool, _ center: BackupCenter) {
        if on {
            if center.prepareAutomatic() { FolderPicker.present { center.chooseFolder($0) } }
        } else {
            center.stopAutomatic()
        }
    }

    // MARK: Recovery passphrase

    private func recovery(_ center: BackupCenter) -> some View {
        Section {
            LabeledContent("Recovery Passphrase") {
                Text(center.hasPassphrase ? "Set" : "Not Set")
                    .foregroundStyle(theme.ink2)
            }
            Button(center.hasPassphrase ? "Change Passphrase…" : "Set Passphrase…") { editingPassphrase = true }
                .disabled(center.account == nil || center.activity != .idle)
                .accessibilityIdentifier("backup.passphrase")
            if center.hasPassphrase {
                Button("Remove Passphrase", role: .destructive) { confirmsRemoval = true }
                    .accessibilityIdentifier("backup.passphrase.remove")
                    .confirmationDialog("Remove the recovery passphrase?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                        Button("Remove Passphrase", role: .destructive) { center.removePassphrase() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(center.keyHome == .deviceOnly
                            ? "Backups already saved still open with it. The key is only on this iPhone, so automatic backup stops."
                            : "Backups already saved still open with it. Backups made from now on open only where the iCloud Keychain key is.")
                    }
            }
        } header: {
            Text("Recovery")
        } footer: {
            VStack(alignment: .leading, spacing: Space.s2) {
                if center.keyHome == .deviceOnly {
                    StatusLine(
                        symbol: "key", tint: theme.accentText,
                        text: "The key that opens a backup is only on this iPhone. Another device needs the passphrase, and automatic backup needs one too."
                    )
                    .accessibilityIdentifier("backup.keyHome")
                }
                Text("With iCloud Keychain on, the key that opens a backup follows the Plex account to a new iPhone. The passphrase opens it anywhere else: on an Android phone, on an iPhone without that key, or once the key is lost. A forgotten passphrase cannot be recovered.")
                    .foregroundStyle(theme.ink2)
            }
        }
        .listRowBackground(theme.sheet)
    }

    // MARK: Pickers

    /// The system pickers hang off empty leaves, one each, so none of them waits on another to close.
    private func pickers(_ center: BackupCenter) -> some View {
        ZStack {
            Color.clear
                .fileExporter(
                    isPresented: Binding(get: { center.exportRequest != nil }, set: { if !$0 { center.exportRequest = nil } }),
                    document: center.exportRequest?.document,
                    contentType: .marqueeBackup,
                    defaultFilename: center.exportRequest?.name
                ) { center.exported($0) }
            Color.clear
                .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.marqueeBackup]) { center.restore(from: $0) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Recovery passphrase sheet

private struct PassphraseSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var again = ""
    @State private var problem: String?
    @State private var saving = false
    @FocusState private var focus: Field?

    private enum Field { case phrase, again }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecureField("Passphrase", text: $phrase, prompt: Text("At least \(BackupFormat.minPassphraseLength) characters").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .phrase)
                        .onSubmit { focus = .again }
                        .accessibilityIdentifier("backup.passphrase.field")
                    SecureField("Repeat", text: $again, prompt: Text("Repeat the passphrase").foregroundStyle(theme.ink3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focus, equals: .again)
                        .onSubmit(save)
                        .accessibilityIdentifier("backup.passphrase.repeat")
                } footer: {
                    if let problem {
                        ProblemLine(text: problem)
                    } else if !again.isEmpty && again != phrase {
                        ProblemLine(text: "The two passphrases are not the same.")
                    } else {
                        Text("It opens a backup on an Android phone, or on an iPhone without this one's iCloud Keychain. Marquee cannot recover it if it is forgotten. A few random words work well.")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .listRowBackground(theme.sheet)
            }
            .themedList(theme)
            .navigationTitle("Recovery Passphrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                        .accessibilityIdentifier("backup.passphrase.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!canSave)
                            .accessibilityIdentifier("backup.passphrase.save")
                    }
                }
            }
            .onAppear { focus = .phrase }
        }
        .interactiveDismissDisabled(saving)
    }

    private var canSave: Bool {
        phrase.count >= BackupFormat.minPassphraseLength && phrase == again
    }

    private func save() {
        guard canSave, !saving else { return }
        saving = true
        problem = nil
        Task {
            problem = await session.backup.setPassphrase(phrase)
            saving = false
            if problem == nil { dismiss() }
        }
    }
}

// MARK: - Restore sheet

private struct RestoreSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var passphrase = ""
    @State private var confirms = false

    var body: some View {
        let center = session.backup
        let step = center.restoreFlow?.step
        NavigationStack {
            Group {
                if let flow = center.restoreFlow {
                    content(flow, center)
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canClose(step) {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { center.closeRestore() }
                            .accessibilityIdentifier("restore.cancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled(!canClose(step))
    }

    /// Applying is all-or-nothing and not interrupted; once done the models still hold the old settings, so
    /// the only way on is to close the app.
    private func canClose(_ step: BackupCenter.RestoreFlow.Step?) -> Bool {
        switch step {
        case .applying, .done: false
        default: true
        }
    }

    @ViewBuilder
    private func content(_ flow: BackupCenter.RestoreFlow, _ center: BackupCenter) -> some View {
        switch flow.step {
        case .reading:
            waiting("Reading the backup…")
        case .applying:
            waiting("Restoring…")
        case .passphrase(let wrong):
            askForPassphrase(wrong: wrong, center)
        case .review:
            review(flow, center)
        case .done:
            done(center)
        case .failed(let message):
            failed(message, center)
        }
    }

    private func waiting(_ text: String) -> some View {
        List {
            Section {
                HStack(spacing: Space.s3) {
                    ProgressView()
                    Text(text).foregroundStyle(theme.ink2)
                }
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
    }

    private func askForPassphrase(wrong: Bool, _ center: BackupCenter) -> some View {
        List {
            Section {
                SecureField("Passphrase", text: $passphrase, prompt: Text("Recovery passphrase").foregroundStyle(theme.ink3))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { submit(center) }
                    .accessibilityIdentifier("restore.passphrase")
                Button("Open Backup") { submit(center) }
                    .disabled(passphrase.isEmpty)
                    .accessibilityIdentifier("restore.open")
            } footer: {
                if wrong {
                    ProblemLine(text: BackupError.wrongPassphrase.message)
                } else {
                    Text(BackupError.needsPassphrase.message)
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
    }

    private func submit(_ center: BackupCenter) {
        guard !passphrase.isEmpty else { return }
        center.submitPassphrase(passphrase)
        passphrase = ""
    }

    private func review(_ flow: BackupCenter.RestoreFlow, _ center: BackupCenter) -> some View {
        let sameKind = flow.header?.app.platform == BackupPlatform.ios
        return List {
            if let header = flow.header {
                Section {
                    LabeledContent("Made") {
                        Text(header.createdDate.stamp).foregroundStyle(theme.ink2)
                    }
                    LabeledContent("Made On") {
                        Text("\(header.app.platform == BackupPlatform.ios ? "iPhone" : "Android phone") · Marquee \(header.app.version)")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .listRowBackground(theme.sheet)
            }
            Section {
                if let contents = flow.contents, !contents.lines.isEmpty {
                    ForEach(contents.lines, id: \.title) { line in
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(line.title)
                            if let detail = line.detail {
                                Text(detail)
                                    .textRole(.caption)
                                    .foregroundStyle(theme.ink2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    Text("Nothing in this backup applies to this iPhone.")
                        .foregroundStyle(theme.ink2)
                }
            } header: {
                Text(sameKind ? "Restores" : "Restores, from an Android phone")
            } footer: {
                Text(sameKind
                    ? "These replace what this iPhone has now. Marquee closes afterwards and starts again from them."
                    : "Only the integrations are portable between Android and iPhone. Everything else on this iPhone stays as it is. Marquee closes afterwards and starts again.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Button("Restore…") { confirms = true }
                    .disabled(flow.contents?.lines.isEmpty ?? true)
                    .accessibilityIdentifier("restore.confirm")
                    .confirmationDialog("Restore this backup?", isPresented: $confirms, titleVisibility: .visible) {
                        Button("Restore", role: .destructive) { center.confirmRestore() }
                            .accessibilityIdentifier("restore.confirm.go")
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The settings it holds replace the ones on this iPhone. If anything fails, nothing is changed.")
                    }
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
    }

    private func done(_ center: BackupCenter) -> some View {
        List {
            Section {
                StatusLine(
                    symbol: "checkmark.circle.fill", tint: theme.positive,
                    text: "The settings are restored. Marquee has to close and open again to start from them."
                )
                Button("Close Marquee") { center.closeApp() }
                    .accessibilityIdentifier("restore.close")
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
    }

    private func failed(_ message: String, _ center: BackupCenter) -> some View {
        List {
            Section {
                ProblemLine(text: message)
                    .accessibilityIdentifier("restore.problem")
                Button("Close") { center.closeRestore() }
                    .accessibilityIdentifier("restore.failed.close")
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
    }
}

private extension Date {
    /// "12 Nov 2026 at 9:41", for a backup's time.
    var stamp: String { formatted(date: .abbreviated, time: .shortened) }
}
