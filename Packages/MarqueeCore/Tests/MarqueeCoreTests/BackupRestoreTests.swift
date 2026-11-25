import Foundation
import Testing
@testable import MarqueeCore

private func entry(_ store: String, _ key: String, _ value: BackupValue, _ group: BackupGroup = .other, item: String? = nil) -> BackupEntry {
    BackupEntry(store: store, key: key, group: group, item: item, value: value)
}

private func defaults(_ key: String, _ value: BackupValue) -> BackupEntry {
    entry(BackupScope.Phone.defaults, key, value)
}

/// A device's storage in memory, able to fail on cue.
private final class FakeStore: BackupStore, @unchecked Sendable {
    var items: [String: BackupEntry] = [:]
    var failWrite: String?
    var failRemove: String?
    /// A failed removal also breaks every write after it, so the undo fails too.
    var breaksUndo = false
    var invalid: String?
    private var broken = false
    private(set) var writes: [String] = []

    init(_ entries: [BackupEntry] = []) {
        for entry in entries { items[entry.id] = entry }
    }

    struct Refused: Error {}

    func read() throws -> [BackupEntry] { Array(items.values) }

    func validate(_ entry: BackupEntry) throws {
        if entry.key == invalid { throw Refused() }
    }

    func write(_ entry: BackupEntry) throws {
        writes.append(entry.key)
        if broken { throw Refused() }
        if entry.key == failWrite {
            failWrite = nil
            throw Refused()
        }
        items[entry.id] = entry
    }

    func remove(_ entry: BackupEntry) throws {
        if entry.key == failRemove {
            broken = breaksUndo
            throw Refused()
        }
        items[entry.id] = nil
    }
}

struct BackupScopeTests {
    @Test func settingsAreInAndTheSignInAndDeviceStateAreOut() {
        let scope = BackupScope.phone
        func group(_ store: String, _ key: String) -> BackupGroup? { scope.classify(store: store, key: key)?.group }
        let d = BackupScope.Phone.defaults

        #expect(group(d, "marquee.settings.3f2a") == .profiles)
        #expect(group(d, "marquee.theme.dark") == .appearance)
        #expect(group(d, "marquee.headerStyle") == .appearance)
        #expect(group(d, "marquee.tabs") == .tabs)
        #expect(group(d, "marquee.tabOrder") == .tabs)
        #expect(group(d, "marquee.server.id") == .servers)
        #expect(group(d, "marquee.remote.dock") == .remote)
        #expect(group(d, "marquee.glasses.kind") == .bigScreen)
        #expect(group(d, "marquee.downloads.settings") == .downloads)
        #expect(group(d, "marquee.live.s.p.favourites") == .live)
        #expect(group(d, "marquee.tracks.s.p.1234") == .tracks)
        #expect(group(d, "marquee.bazarr.address") == .integrations)
        #expect(group(d, "marquee.somethingNew") == .other)
        #expect(group(BackupScope.Phone.remote, "phoneName") == .remote)
        #expect(group(BackupScope.Phone.tv, "tv-1") == .tvs)

        let left = [
            (d, "marquee.server.address.abc"), (d, "marquee.profile"), (d, "marquee.backup.folder"), (d, "marquee.account.id"),
            (d, "marquee.link.name"), (d, "marquee.link.enabled"), (d, "marquee.uitest.live"), (d, "marquee.fakeSignedIn"),
            (d, "marquee.downloads.backgroundBroken"), (d, "marquee.diag.name"), (d, "plex.clientIdentifier"),
            (d, "plex.accountToken"), (d, "library.section"), (d, "search.recents"),
            (BackupScope.Phone.secret, "plex.accountToken"), (BackupScope.Phone.secret, "plex.servers"),
            (BackupScope.Phone.secret, "marquee.seerr.session"), (BackupScope.Phone.secret, "link.vault"),
            (BackupScope.Phone.secret, "marquee.backup.keyring"), (BackupScope.Phone.secret, "marquee.anything.else"),
            ("keychain", "marquee.bazarr.key"),
        ]
        for (store, key) in left {
            #expect(scope.classify(store: store, key: key) == nil, "\(store) \(key)")
        }
    }

    @Test func everyIntegrationSecretIsNamedAndOnlyThose() {
        let scope = BackupScope.phone
        let secrets = [
            "marquee.bazarr.key": "Bazarr", "marquee.radarr.key": "Radarr", "marquee.sonarr.key": "Sonarr",
            "marquee.homelabber.token": "HomeLabber", "marquee.seerr.key": "Seerr", "marquee.diag.token": "Diagnostic Logs",
        ]
        for (key, item) in secrets {
            #expect(scope.classify(store: BackupScope.Phone.secret, key: key) == .init(group: .integrations, item: item))
        }
    }

    @Test func addressesAreURLsAndTheRestAreNot() {
        let scope = BackupScope.phone
        for key in ["marquee.seerr.address", "marquee.radarr.address", "marquee.sonarr.address", "marquee.bazarr.address", "marquee.homelabber.address"] {
            #expect(scope.classify(store: "defaults", key: key)?.isURL == true, "\(key)")
        }
        for key in ["marquee.speechDock.address", "marquee.diag.server", "marquee.seerr.pulsarr"] {
            #expect(scope.classify(store: "defaults", key: key)?.isURL == false, "\(key)")
        }
    }

    @Test func integrationsTravelBetweenThePhoneAndTheOtherPlatform() {
        let d = BackupScope.Phone.defaults
        let entries = [
            entry(d, "marquee.seerr.address", .string("https://seerr.example")),
            entry(d, "marquee.seerr.pulsarr", .bool(true)),
            entry(BackupScope.Phone.secret, "marquee.seerr.key", .string("seerr-key")),
            entry(d, "marquee.bazarr.address", .string("https://bazarr.example")),
            entry(d, "marquee.speechDock.address", .string("https://speech.example")),
            entry(d, "marquee.diag.server", .string("https://ntfy.example")),
            entry(d, "marquee.diag.topic", .string("logs")),
            entry(BackupScope.Phone.secret, "marquee.diag.token", .string("tk_123")),
            entry(d, "marquee.radarr.address", .string("")),
            entry(d, "marquee.theme.dark", .string("not an integration")),
        ]
        let integrations = BackupScope.integrations(fromPhone: entries)
        #expect(Set(integrations.keys) == ["seerr", "bazarr", "speechDock", "diagnostics"])
        #expect(integrations["seerr"] == BackupIntegration(address: "https://seerr.example", secret: "seerr-key", options: ["pulsarr": "true"]))
        #expect(integrations["diagnostics"] == BackupIntegration(address: "https://ntfy.example", secret: "tk_123", options: ["topic": "logs"]))

        let back = BackupScope.phoneEntries(from: integrations)
        #expect(Set(back.map(\.id)) == Set(entries.prefix(8).map(\.id)))
        #expect(back.first { $0.key == "marquee.seerr.pulsarr" }?.value == .bool(true))
        #expect(back.first { $0.key == "marquee.seerr.key" }?.group == .integrations)
        #expect(back.first { $0.key == "marquee.bazarr.address" }?.item == "Bazarr")
    }

    @Test func theRestoreListNamesWhatChangesAndNeverAValue() {
        let payload = BackupPayload(platform: "ios", appVersion: "1", entries: [
            entry("defaults", "marquee.settings.a", .data(Data()), .profiles),
            entry("defaults", "marquee.settings.b", .data(Data()), .profiles),
            entry("defaults", "marquee.theme.dark", .string("hunter2"), .appearance),
            entry("secret", "marquee.seerr.key", .string("hunter2"), .integrations, item: "Seerr"),
            entry("secret", "marquee.bazarr.key", .string("hunter2"), .integrations, item: "Bazarr"),
            entry("tv", "1", .data(Data()), .tvs, item: "Living Room"),
            entry("defaults", "marquee.tracks.x", .data(Data()), .tracks),
            entry("defaults", "marquee.odd", .bool(true), BackupGroup(rawValue: "from-the-future")),
        ])
        let contents = BackupContents(payload, restoringOn: "ios")
        #expect(contents.lines.map(\.title) == [
            "Profile settings", "Appearance and themes", "Integrations and their keys", "Paired TVs",
            "Remembered audio and subtitle choices", "Other settings",
        ])
        #expect(contents.lines.map(\.detail) == ["2 profiles", nil, "Bazarr, Seerr", "Living Room", "1 title", nil])
        #expect(!String(describing: contents).contains("hunter2"))

        let other = BackupContents(BackupPayload(platform: "android", appVersion: "1", entries: payload.entries, integrations: [
            "seerr": BackupIntegration(address: "https://s"), "bazarr": BackupIntegration(address: "https://b"),
        ]), restoringOn: "ios")
        #expect(other.lines == [.init(title: "Integrations and their keys", detail: "Bazarr, Seerr")])
    }
}

struct BackupRestoreTests {
    private let oldTheme = defaults("marquee.theme.dark", .string("old"))
    private let extra = defaults("marquee.tabs", .strings(["home"]))
    private let secret = entry(BackupScope.Phone.secret, "marquee.bazarr.key", .string("old-key"))

    private func payload(_ entries: [BackupEntry]) -> BackupPayload {
        BackupPayload(platform: "ios", appVersion: "1", entries: entries)
    }

    @Test func aRestoreReplacesWhatTheBackupCoversAndRemovesWhatItLacks() throws {
        let store = FakeStore([oldTheme, extra, secret])
        let plan = BackupRestore.plan(payload([defaults("marquee.theme.dark", .string("new")), defaults("marquee.headerStyle", .string("large"))]))
        try BackupRestore.apply(plan, to: store)
        #expect(store.items.values.map(\.key).sorted() == ["marquee.headerStyle", "marquee.theme.dark"])
        #expect(store.items[oldTheme.id]?.value == .string("new"))
    }

    @Test func aFailureAnywhereLeavesEverythingAsItWas() throws {
        for failing in ["marquee.headerStyle", "marquee.bazarr.key", "marquee.theme.dark"] {
            let store = FakeStore([oldTheme, extra, secret])
            let before = store.items
            store.failWrite = failing
            let plan = BackupRestore.plan(payload([
                defaults("marquee.theme.dark", .string("new")), defaults("marquee.headerStyle", .string("large")),
                entry(BackupScope.Phone.secret, "marquee.bazarr.key", .string("new-key")),
            ]))
            #expect(throws: BackupError.restoreFailed) { try BackupRestore.apply(plan, to: store) }
            #expect(store.items == before, "failing on \(failing)")
        }
    }

    @Test func aFailedRemovalIsUndoneToo() throws {
        let store = FakeStore([oldTheme, extra, secret])
        let before = store.items
        store.failRemove = "marquee.tabs"
        let plan = BackupRestore.plan(payload([defaults("marquee.theme.dark", .string("new"))]))
        #expect(throws: BackupError.restoreFailed) { try BackupRestore.apply(plan, to: store) }
        #expect(store.items == before)
    }

    @Test func anUndoThatFailsIsReportedAsIncomplete() throws {
        let store = FakeStore([oldTheme, extra, secret])
        store.failRemove = "marquee.tabs"
        store.breaksUndo = true
        let plan = BackupRestore.plan(payload([defaults("marquee.theme.dark", .string("new"))]))
        #expect(throws: BackupError.restoreIncomplete) { try BackupRestore.apply(plan, to: store) }
    }

    @Test func anEntryTheDeviceCannotTakeStopsTheRestoreBeforeAnythingIsWritten() throws {
        let store = FakeStore([oldTheme])
        store.invalid = "marquee.headerStyle"
        let plan = BackupRestore.plan(payload([defaults("marquee.theme.dark", .string("new")), defaults("marquee.headerStyle", .string("x"))]))
        #expect(throws: BackupError.restoreFailed) { try BackupRestore.apply(plan, to: store) }
        #expect(store.writes.isEmpty)
        #expect(store.items[oldTheme.id]?.value == .string("old"))
    }

    @Test func secretsAreWrittenFirstAndUnchangedEntriesNotAtAll() throws {
        let store = FakeStore([oldTheme])
        let plan = BackupRestore.plan(payload([
            defaults("marquee.theme.dark", .string("old")), defaults("marquee.headerStyle", .string("large")),
            entry(BackupScope.Phone.secret, "marquee.bazarr.key", .string("k")),
        ]))
        try BackupRestore.apply(plan, to: store)
        #expect(store.writes == ["marquee.bazarr.key", "marquee.headerStyle"])
    }

    @Test func nothingOutsideTheScopeIsEverWritten() throws {
        let store = FakeStore()
        let plan = BackupRestore.plan(payload([
            entry(BackupScope.Phone.secret, "plex.accountToken", .string("stolen")),
            entry(BackupScope.Phone.secret, "marquee.seerr.session", .string("cookie")),
            defaults("marquee.link.name", .string("x")), defaults("plex.clientIdentifier", .string("x")),
            defaults("marquee.theme.dark", .string("ok")),
        ]))
        #expect(plan.entries.map(\.key) == ["marquee.theme.dark"])
        try BackupRestore.apply(Plan(entries: [entry(BackupScope.Phone.secret, "plex.accountToken", .string("stolen"))], replacesAll: true), to: store)
        #expect(store.items.isEmpty)
    }

    @Test func aBackupFromTheOtherPlatformOnlySetsItsIntegrations() throws {
        let radarr = entry(BackupScope.Phone.secret, "marquee.radarr.key", .string("radarr-key"))
        let store = FakeStore([oldTheme, radarr, defaults("marquee.radarr.address", .string("https://radarr.example"))])
        let android = BackupPayload(platform: "android", appVersion: "0.16", entries: [
            entry("settings", "theme.dark", .string("android-only")),
        ], integrations: [
            "bazarr": BackupIntegration(address: "https://bazarr.example", secret: "bazarr-key"),
            "seerr": BackupIntegration(address: "https://seerr.example", options: ["pulsarr": "false"]),
        ])
        let plan = BackupRestore.plan(android)
        #expect(plan.replacesAll == false)
        try BackupRestore.apply(plan, to: store)
        #expect(store.items[oldTheme.id]?.value == .string("old"))
        #expect(store.items[radarr.id]?.value == .string("radarr-key"))
        #expect(store.items["secret\u{0}marquee.bazarr.key"]?.value == .string("bazarr-key"))
        #expect(store.items["defaults\u{0}marquee.seerr.address"]?.value == .string("https://seerr.example"))
        #expect(store.items["defaults\u{0}marquee.seerr.pulsarr"]?.value == .bool(false))
        #expect(store.items["defaults\u{0}theme.dark"] == nil)
    }
}

struct BackupSnapshotTests {
    @Test func aSnapshotHoldsOnlyWhatIsInScopeInAFixedOrder() throws {
        let store = FakeStore([
            defaults("marquee.tabs", .strings(["home"])), defaults("marquee.theme.dark", .string("x")),
            defaults("marquee.link.name", .string("not backed up")),
            entry(BackupScope.Phone.secret, "marquee.bazarr.key", .string("k")), defaults("marquee.bazarr.address", .string("https://b")),
        ])
        let payload = try BackupSnapshot.make(from: store, platform: "ios", appVersion: "1")
        #expect(payload.entries.map(\.key) == ["marquee.bazarr.address", "marquee.tabs", "marquee.theme.dark", "marquee.bazarr.key"])
        #expect(payload.integrations["bazarr"] == BackupIntegration(address: "https://b", secret: "k"))
    }

    @Test func theFingerprintChangesWithTheSettingsAndTheKeyAndNothingElse() throws {
        let key = Data(repeating: 7, count: 32)
        let store = FakeStore([defaults("marquee.tabs", .strings(["home"]))])
        let first = try BackupSnapshot.make(from: store, platform: "ios", appVersion: "1")
        let later = try BackupSnapshot.make(from: store, platform: "ios", appVersion: "2")
        #expect(BackupSnapshot.fingerprint(first, key: key) == BackupSnapshot.fingerprint(later, key: key))
        #expect(BackupSnapshot.fingerprint(first, key: key) != BackupSnapshot.fingerprint(first, key: Data(repeating: 8, count: 32)))

        try store.write(defaults("marquee.tabs", .strings(["home", "live"])))
        let changed = try BackupSnapshot.make(from: store, platform: "ios", appVersion: "1")
        #expect(BackupSnapshot.fingerprint(first, key: key) != BackupSnapshot.fingerprint(changed, key: key))
    }

    @Test func secretsAreNamedNeverSearchedFor() {
        #expect(Set(BackupScope.phone.keys(in: BackupScope.Phone.secret)) == [
            "marquee.seerr.key", "marquee.radarr.key", "marquee.sonarr.key", "marquee.bazarr.key",
            "marquee.homelabber.token", "marquee.diag.token",
        ])
    }
}

private typealias Plan = BackupRestore.Plan
