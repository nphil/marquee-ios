import Foundation
import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import Observation
import UIKit

/// Backup and restore of the iPhone's settings (DESIGN §8.13): the encrypted file, the file that is kept
/// up to date, the key and recovery passphrase that open it, and the restore that puts it back. What is in a
/// backup is `BackupScope.phone`; the file format and the all-or-nothing restore are `MarqueeCore`'s.
///
/// Secrets, values and paths never reach the diagnostic log: events carry counts and outcomes only.
@MainActor @Observable
final class BackupCenter {
    enum Activity: Equatable {
        case idle
        case working(String)
    }

    struct ExportRequest {
        var document: BackupDocument
        var name: String
    }

    /// One restore, a step at a time. The file and what opened it stay in the center, out of the view's reach.
    struct RestoreFlow: Identifiable {
        enum Step: Equatable {
            case reading
            case passphrase(wrong: Bool)
            case review
            case applying
            case done
            case failed(String)
        }

        let id = UUID()
        var step = Step.reading
        var header: BackupHeader?
        var contents: BackupContents?
    }

    private(set) var account: String?
    private(set) var activity = Activity.idle
    /// What went wrong with the last thing the person asked for, in plain words.
    private(set) var problem: String?
    private(set) var lastBackup: Date?
    private(set) var fileName: String?
    /// Where the chosen file lives, e.g. "iCloud Drive › Marquee".
    private(set) var filePlace: String?
    private(set) var lastAutomatic: Date?
    /// Why the last automatic backup was not saved.
    private(set) var automaticProblem: String?
    private(set) var hasPassphrase = false
    /// Where the key lives; nil until the first backup makes it.
    private(set) var keyHome: BackupKeyringStore.Home?
    /// The chosen file holds a backup newer than anything this iPhone wrote or restored: automatic backup waits for
    /// the person to choose between restoring it and replacing it.
    private(set) var foundNewer: Date?
    var exportRequest: ExportRequest?
    var restoreFlow: RestoreFlow?
    /// A backup opened from Files, waiting for the Backup page to take it up.
    private(set) var pendingOpen: URL?

    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private let keyrings: BackupKeyringStore
    @ObservationIgnored private let pairings: any PairingStore
    @ObservationIgnored private var fileBookmark: Data?
    @ObservationIgnored private var lastFingerprint: Data?
    /// The `createdAt` of the newest backup in the file that this iPhone wrote or restored.
    @ObservationIgnored private var newest = 0
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var pendingFile: Data?
    @ObservationIgnored private var opened: OpenedBackup?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// The Backup page is on screen, so a file opened from Files is taken up there and no second page opens.
    @ObservationIgnored var pageIsOpen = false

    private enum Key {
        static let file = "marquee.backup.file"
        static let fileName = "marquee.backup.fileName"
        static let filePlace = "marquee.backup.filePlace"
        /// The folder bookmark of 0.1.93 and before; it is dropped, the file is chosen again.
        static let oldFolder = "marquee.backup.folder"
        static let oldFolderName = "marquee.backup.folderName"
        static let fingerprint = "marquee.backup.fingerprint"
        static let newest = "marquee.backup.newest"
        static let last = "marquee.backup.last"
        static let lastAutomatic = "marquee.backup.lastAutomatic"
    }

    /// Seconds of quiet after a settings change before an automatic backup is written.
    private static let quiet = 20
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    init(storage: SessionStorage) {
        self.storage = storage
        let live = storage.keychain != nil
        keyrings = live ? .live() : .inMemory()
        pairings = live ? KeychainPairingStore() : MemoryPairingStore()
        account = storage.accountID
        let defaults = storage.defaults
        for key in [Key.oldFolder, Key.oldFolderName] { defaults.removeObject(forKey: key) }
        fileBookmark = defaults.data(forKey: Key.file)
        fileName = fileBookmark == nil ? nil : defaults.string(forKey: Key.fileName)
        filePlace = fileBookmark == nil ? nil : defaults.string(forKey: Key.filePlace)
        lastFingerprint = defaults.data(forKey: Key.fingerprint)
        newest = defaults.integer(forKey: Key.newest)
        lastBackup = Self.date(defaults, Key.last)
        lastAutomatic = Self.date(defaults, Key.lastAutomatic)
    }

    var automaticIsOn: Bool { fileName != nil }

    /// Without iCloud Keychain the key stays on this iPhone, so only a recovery passphrase lets another device
    /// open an automatic backup: it is required before one is written.
    var automaticNeedsPassphrase: Bool { keyHome == .deviceOnly && !hasPassphrase }

    /// The Settings row's value.
    var summary: String {
        if foundNewer != nil || automaticProblem != nil { return "Needs attention" }
        return automaticIsOn ? "On" : "Off"
    }

    // MARK: Session

    /// Watches for changes worth a new automatic backup. Called once, when the session is made.
    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            },
        ]
        settingsMayHaveChanged()
    }

    /// The Plex account backups belong to, nil when signed out.
    func setAccount(_ id: String?) {
        guard id != account else { return }
        account = id
        storage.accountID = id
        hasPassphrase = false
        keyHome = nil
    }

    /// Delete All Local Data: the file choice, the bookkeeping and the account go. The key stays in the Keychain, so
    /// the backups already made can still be opened after signing in again.
    func reset() {
        stopAutomatic()
        setAccount(nil)
        lastBackup = nil
        newest = 0
        problem = nil
        closeRestore()
        exportRequest = nil
    }

    /// The Backup page appeared.
    func refresh() {
        problem = nil
        guard let account else { return }
        if let found = try? keyrings.load(account: account) {
            keyHome = found.home
            hasPassphrase = found.keyring.hasPassphrase
        }
        guard fileBookmark != nil, foundNewer == nil, !writing else { return }
        Task { await checkFile(account: account) }
    }

    // MARK: Back up now

    func backUpNow() {
        problem = nil
        guard activity == .idle else { return }
        guard let account else {
            problem = BackupError.noAccount.message
            return
        }
        activity = .working("Preparing the backup")
        Task {
            defer { activity = .idle }
            do {
                let keyring = try loadKeyring(for: account)
                let made = try snapshot(keyring: keyring)
                let file = try await seal(made.payload, account: account, keyring: keyring, now: .now)
                exportRequest = ExportRequest(document: BackupDocument(data: file), name: BackupFormat.fileName(on: .now))
                Diag.event(.app, "backup.export", [
                    "entries": made.payload.entries.count, "bytes": file.count, "passphrase": keyring.hasPassphrase,
                ], .notice)
            } catch {
                problem = Self.words(for: error)
                Diag.event(.app, "backup.export.failed", ["reason": Self.reason(error)], .warning)
            }
        }
    }

    /// The system's file exporter finished.
    func exported(_ result: Result<URL, any Error>) {
        switch result {
        case .success:
            let now = Date.now
            lastBackup = now
            storage.defaults.set(now.timeIntervalSince1970, forKey: Key.last)
            Diag.event(.app, "backup.exported", [:], .notice)
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            problem = Self.words(for: error)
            Diag.event(.app, "backup.export.failed", ["reason": Self.reason(error)], .warning)
        }
    }

    // MARK: Recovery passphrase

    /// Sets or changes the passphrase. Returns what to tell the person when it was refused, nil when it is set.
    func setPassphrase(_ phrase: String) async -> String? {
        guard let account else { return BackupError.noAccount.message }
        activity = .working("Securing the passphrase")
        defer { activity = .idle }
        do {
            let current = try loadKeyring(for: account)
            let stretched = try await Task.detached(priority: .userInitiated) {
                var copy = current
                try copy.setPassphrase(phrase)
                return copy
            }.value
            keyHome = try keyrings.save(stretched, account: account)
            hasPassphrase = true
            keyChanged()
            Diag.event(.app, "backup.passphrase.set", [:], .notice)
            return nil
        } catch {
            return Self.words(for: error)
        }
    }

    func removePassphrase() {
        problem = nil
        guard let account else { return }
        do {
            var keyring = try loadKeyring(for: account)
            keyring.removePassphrase()
            keyHome = try keyrings.save(keyring, account: account)
            hasPassphrase = false
            keyChanged()
            Diag.event(.app, "backup.passphrase.removed", [:], .notice)
            if automaticNeedsPassphrase {
                stopAutomatic()
                problem = Self.passphraseNeeded
            }
        } catch {
            problem = Self.words(for: error)
        }
    }

    // MARK: Restore

    /// The file the person picked in Files.
    func restore(from result: Result<URL, any Error>) {
        switch result {
        case .success(let url): beginRestore { try await BackupFiles.blocking { try BackupFiles.read(picked: url) } }
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            problem = Self.words(for: error)
        }
    }

    func restoreFromChosenFile() {
        guard let bookmark = fileBookmark else { return }
        beginRestore {
            guard let file = try await BackupFiles.blocking({ try BackupFiles.current(at: bookmark) }) else {
                throw BackupError.notABackup
            }
            return file
        }
    }

    /// A backup opened from Files (the system hands it to the app): the Backup page picks it up.
    func open(file url: URL) {
        if let superseded = pendingOpen, superseded != url { BackupFiles.removeInboxCopy(superseded) }
        pendingOpen = url
    }

    func takePendingOpen() {
        guard let url = pendingOpen else { return }
        pendingOpen = nil
        restore(from: .success(url))
    }

    func submitPassphrase(_ phrase: String) {
        guard let file = pendingFile, let account else { return }
        restoreFlow?.step = .reading
        Task {
            let keyring = (try? keyrings.load(account: account))?.keyring
            do {
                try await unlock(file, account: account, keyring: keyring, passphrase: phrase)
            } catch BackupError.wrongPassphrase {
                restoreFlow?.step = .passphrase(wrong: true)
            } catch {
                failRestore(error)
            }
        }
    }

    /// Writes the opened backup to the iPhone, all or nothing.
    func confirmRestore() {
        guard let opened, let account, restoreFlow?.step == .review else { return }
        restoreFlow?.step = .applying
        do {
            var keyring = try loadKeyring(for: account)
            let before = keyring
            // Backups made from here on carry the passphrase that opened this one.
            keyring.adopt(opened.passphraseKey)
            if keyring != before {
                keyHome = try keyrings.save(keyring, account: account)
                hasPassphrase = keyring.hasPassphrase
                lastFingerprint = nil
            }
            let plan = BackupRestore.plan(opened.payload)
            try BackupRestore.apply(plan, to: store)
            newest = max(newest, opened.header.createdAt)
            storage.defaults.set(newest, forKey: Key.newest)
            foundNewer = nil
            restoreFlow?.step = .done
            Diag.event(.app, "backup.restored", ["entries": plan.entries.count, "from": opened.header.app.platform], .notice)
        } catch {
            failRestore(error)
        }
    }

    func closeRestore() {
        restoreFlow = nil
        pendingFile = nil
        opened = nil
    }

    /// Ends the app so it starts again from what was restored: the models in memory were built from the old
    /// settings and would write them back.
    func closeApp() {
        exit(0)
    }

    private func beginRestore(_ read: @escaping @Sendable () async throws -> Data) {
        guard restoreFlow == nil else { return }
        problem = nil
        restoreFlow = RestoreFlow()
        Task {
            do {
                try await prepare(try await read())
            } catch {
                failRestore(error)
            }
        }
    }

    private func prepare(_ file: Data) async throws {
        guard let account else { throw BackupError.noAccount }
        let header = try Backup.inspect(file)
        restoreFlow?.header = header
        guard Backup.belongs(header, to: account) else { throw BackupError.wrongAccount }
        pendingFile = file
        let keyring = (try? keyrings.load(account: account))?.keyring
        do {
            try await unlock(file, account: account, keyring: keyring, passphrase: nil)
        } catch BackupError.needsPassphrase {
            restoreFlow?.step = .passphrase(wrong: false)
        }
    }

    private func unlock(_ file: Data, account: String, keyring: BackupKeyring?, passphrase: String?) async throws {
        let backup = try await Task.detached(priority: .userInitiated) {
            try Backup.open(file, account: account, keyring: keyring, passphrase: passphrase)
        }.value
        guard restoreFlow != nil else { return }
        opened = backup
        restoreFlow?.header = backup.header
        restoreFlow?.contents = BackupContents(backup.payload, restoringOn: BackupPlatform.ios)
        restoreFlow?.step = .review
        Diag.event(.app, "backup.restore.opened", ["from": backup.header.app.platform, "entries": backup.payload.entries.count])
    }

    private func failRestore(_ error: any Error) {
        guard restoreFlow != nil else { return }
        restoreFlow?.step = .failed(Self.words(for: error))
        Diag.event(.app, "backup.restore.failed", ["reason": Self.reason(error)], .warning)
    }

    // MARK: Automatic backup

    /// Whether the file picker can open: the key must exist and, without iCloud Keychain, a passphrase too.
    func prepareAutomatic() -> Bool {
        problem = nil
        guard let account else {
            problem = BackupError.noAccount.message
            return false
        }
        do {
            _ = try loadKeyring(for: account)
        } catch {
            problem = Self.words(for: error)
            return false
        }
        guard !automaticNeedsPassphrase else {
            problem = Self.passphraseNeeded
            return false
        }
        return true
    }

    /// "Choose Backup File": with no backup made yet the first one is saved where the person picks, otherwise
    /// an existing backup is picked. Either way the file is then kept up to date in place.
    func chooseBackupFile() {
        guard prepareAutomatic(), activity == .idle, let account else { return }
        guard lastBackup == nil else {
            FilePicker.open { [weak self] in self?.chooseFile($0) }
            return
        }
        activity = .working("Preparing the backup")
        Task {
            defer { activity = .idle }
            do {
                let keyring = try loadKeyring(for: account)
                let made = try snapshot(keyring: keyring)
                let now = Date.now
                let data = try await seal(made.payload, account: account, keyring: keyring, now: now)
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let temp = folder.appending(path: BackupFormat.fileName(on: now))
                try data.write(to: temp)
                FilePicker.save(temp) { [weak self] result in
                    try? FileManager.default.removeItem(at: folder)
                    if case .success = result {
                        self?.newest = Int(now.timeIntervalSince1970)
                        self?.storage.defaults.set(self?.newest ?? 0, forKey: Key.newest)
                    }
                    self?.chooseFile(result)
                }
            } catch {
                failFile(error)
            }
        }
    }

    private func chooseFile(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            Diag.event(.app, "backup.auto", ["file": "chosen"], .notice)
            adopt(file: url)
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            failFile(error)
        }
    }

    /// Every way choosing the file can fail ends here, in a sentence beside the switch and in the log.
    private func failFile(_ error: any Error) {
        let words = Self.words(for: error)
        problem = words
        automaticProblem = words
        Diag.event(.app, "backup.auto", ["file": "failed", "reason": Self.reason(error)], .warning)
    }

    func stopAutomatic() {
        pendingCheck?.cancel()
        pendingCheck = nil
        fileBookmark = nil
        fileName = nil
        filePlace = nil
        lastFingerprint = nil
        lastAutomatic = nil
        foundNewer = nil
        automaticProblem = nil
        let defaults = storage.defaults
        for key in [Key.file, Key.fileName, Key.filePlace, Key.fingerprint, Key.lastAutomatic] { defaults.removeObject(forKey: key) }
        Diag.event(.app, "backup.auto.off", [:], .notice)
    }

    /// The person chose to keep this iPhone's settings over the newer backup in the file.
    func replaceNewerInFile() {
        foundNewer = nil
        lastFingerprint = nil
        Task { await writeIfChanged(replacingNewer: true) }
    }

    private func adopt(file url: URL) {
        guard let account else {
            failFile(BackupError.noAccount)
            return
        }
        problem = nil
        activity = .working("Checking the file")
        Task {
            defer { activity = .idle }
            do {
                let bookmark = try await BackupFiles.blocking { try BackupFiles.bookmark(for: url) }
                let existing = try await BackupFiles.blocking { try BackupFiles.current(at: bookmark) }
                let found = existing.flatMap { try? Backup.inspect($0) }
                if let found, !Backup.belongs(found, to: account) {
                    failFile(BackupFiles.Failure.otherAccount)
                    return
                }
                fileBookmark = bookmark
                fileName = url.lastPathComponent
                filePlace = BackupFiles.place(of: url)
                lastFingerprint = nil
                automaticProblem = nil
                let defaults = storage.defaults
                defaults.set(bookmark, forKey: Key.file)
                defaults.set(fileName, forKey: Key.fileName)
                defaults.set(filePlace, forKey: Key.filePlace)
                defaults.removeObject(forKey: Key.fingerprint)
                Diag.event(.app, "backup.auto.on", ["found": found != nil], .notice)
                if let found, found.createdAt > newest {
                    foundNewer = found.createdDate
                } else {
                    await writeIfChanged()
                }
            } catch {
                failFile(error)
            }
        }
    }

    private func checkFile(account: String) async {
        guard let bookmark = fileBookmark else { return }
        do {
            let existing = try await BackupFiles.blocking { try BackupFiles.current(at: bookmark) }
            guard let header = existing.flatMap({ try? Backup.inspect($0) }),
                  Backup.belongs(header, to: account), header.createdAt > newest
            else { return }
            foundNewer = header.createdDate
        } catch {
            automaticProblem = Self.words(for: error)
        }
    }

    private func settingsMayHaveChanged() {
        guard fileBookmark != nil, pendingCheck == nil else { return }
        pendingCheck = Task {
            try? await Task.sleep(for: .seconds(Self.quiet))
            guard !Task.isCancelled else { return }
            pendingCheck = nil
            await writeIfChanged()
        }
    }

    /// The app is leaving the foreground: write at once, and ask iOS for the few seconds it takes.
    private func flush() {
        guard fileBookmark != nil else { return }
        pendingCheck?.cancel()
        pendingCheck = nil
        let owns = backgroundTask == .invalid
        if owns {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "marquee-backup") { [weak self] in
                // iOS ends the app unless the assertion ends before this handler returns.
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
        Task {
            await writeIfChanged()
            if owns { endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Rewrites the chosen file when the settings differ from what was last written.
    private func writeIfChanged(replacingNewer: Bool = false) async {
        guard let bookmark = fileBookmark, let account, foundNewer == nil, !writing else { return }
        writing = true
        defer { writing = false }
        do {
            let keyring = try loadKeyring(for: account)
            guard !automaticNeedsPassphrase else {
                automaticProblem = Self.passphraseNeeded
                return
            }
            let made = try snapshot(keyring: keyring)
            guard made.fingerprint != lastFingerprint else { return }
            let now = Date.now
            let file = try await seal(made.payload, account: account, keyring: keyring, now: now)
            let known = newest
            let refreshed = try await BackupFiles.blocking {
                try BackupFiles.write(file, at: bookmark, account: account, knownNewest: known, replacingNewer: replacingNewer)
            }
            let defaults = storage.defaults
            if let refreshed {
                fileBookmark = refreshed
                defaults.set(refreshed, forKey: Key.file)
            }
            lastFingerprint = made.fingerprint
            newest = Int(now.timeIntervalSince1970)
            lastBackup = now
            lastAutomatic = now
            automaticProblem = nil
            defaults.set(made.fingerprint, forKey: Key.fingerprint)
            defaults.set(newest, forKey: Key.newest)
            defaults.set(now.timeIntervalSince1970, forKey: Key.last)
            defaults.set(now.timeIntervalSince1970, forKey: Key.lastAutomatic)
            Diag.event(.app, "backup.auto.written", ["entries": made.payload.entries.count, "bytes": file.count])
        } catch BackupFiles.Failure.newer(let date) {
            foundNewer = date
            Diag.event(.app, "backup.auto.newer", [:], .notice)
        } catch BackupFiles.Failure.otherAccount {
            stopAutomatic()
            problem = Self.words(for: BackupFiles.Failure.otherAccount)
        } catch {
            automaticProblem = Self.words(for: error)
            Diag.event(.app, "backup.auto.failed", ["reason": Self.reason(error)], .warning)
        }
    }

    // MARK: Pieces

    private var store: PhoneBackupStore {
        PhoneBackupStore(
            defaults: storage.defaults, domain: storage.domain, remoteSuite: RemoteSettings.suiteName,
            keychain: storage.keychain, pairings: pairings
        )
    }

    /// The account's keyring, made on first use. Making it late is deliberate: an iPhone that has not yet
    /// received the iCloud Keychain item from another one must not be given a new key to replace it.
    private func loadKeyring(for account: String) throws -> BackupKeyring {
        if let found = try keyrings.load(account: account) {
            keyHome = found.home
            hasPassphrase = found.keyring.hasPassphrase
            return found.keyring
        }
        let made = BackupKeyring.create()
        keyHome = try keyrings.save(made, account: account)
        hasPassphrase = false
        return made
    }

    /// A change to the passphrase must reach the chosen file even when the settings did not change.
    private func keyChanged() {
        lastFingerprint = nil
        storage.defaults.removeObject(forKey: Key.fingerprint)
        settingsMayHaveChanged()
    }

    private func snapshot(keyring: BackupKeyring) throws -> (payload: BackupPayload, fingerprint: Data) {
        let payload = try BackupSnapshot.make(from: store, platform: BackupPlatform.ios, appVersion: Self.appVersion)
        return (payload, BackupSnapshot.fingerprint(payload, key: keyring.secret))
    }

    private func seal(_ payload: BackupPayload, account: String, keyring: BackupKeyring, now: Date) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Backup.seal(payload, account: account, keyring: keyring, now: now)
        }.value
    }

    private static func date(_ defaults: UserDefaults, _ key: String) -> Date? {
        (defaults.object(forKey: key) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static let passphraseNeeded = "Set a recovery passphrase first. Without iCloud Keychain, only the passphrase can open this backup on another device."

    /// The sentence to show for a failure.
    static func words(for error: any Error) -> String {
        switch error {
        case let error as BackupError:
            return error.message
        case let error as BackupFiles.Failure:
            switch error {
            case .notDownloaded: return "iCloud has not downloaded the backup to this iPhone yet. Try again when it is online."
            case .otherAccount: return "That file holds the backup of another Plex account. Choose a different file."
            case .newer: return "That file holds a newer backup."
            case .fileUnavailable: return "Marquee can no longer reach the backup file. Choose it again."
            }
        case is KeychainError:
            return "Marquee could not reach the Keychain. Unlock the iPhone and try again."
        case let error as CocoaError where error.code == .fileWriteOutOfSpace:
            return "There is not enough space to save the backup."
        case let error as CocoaError where error.code == .fileReadNoPermission || error.code == .fileWriteNoPermission:
            return "Marquee is not allowed to use that location. Choose it again."
        default:
            return "The backup could not be saved or read."
        }
    }

    /// A name for the log: the kind of failure, never a path or a message the system wrote.
    private static func reason(_ error: any Error) -> String {
        switch error {
        case let error as BackupError: String(describing: error)
        case let error as BackupFiles.Failure: String(describing: error)
        case is KeychainError: "keychain"
        case let error as CocoaError: "cocoa.\(error.code.rawValue)"
        default: "other"
        }
    }
}
