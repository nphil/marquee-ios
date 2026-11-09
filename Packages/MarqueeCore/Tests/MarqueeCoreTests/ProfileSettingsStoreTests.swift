import Foundation
import Testing
@testable import MarqueeCore

private final class Blobs: SettingsBlobStore {
    var data: [String: Data] = [:]
    func blob(forKey key: String) -> Data? { data[key] }
    func setBlob(_ value: Data?, forKey key: String) { data[key] = value }
}

private struct Prefs: Codable, Equatable {
    var layout = HomeLayout()
}

struct ProfileSettingsStoreTests {
    private let blobs = Blobs()
    private var store: ProfileSettingsStore<Prefs> {
        ProfileSettingsStore(prefix: "settings.", blobs: blobs) { Prefs() }
    }

    private func hidden(_ id: String) -> Prefs {
        Prefs(layout: HomeLayout(placements: [.init(id: id, shown: false)]))
    }

    @Test func eachProfileReadsBackWhatItSavedUnderItsOwnUUID() {
        store.save(hidden("home.ondeck"), profile: "owner")
        store.save(hidden("home.continue"), profile: "isabel")

        #expect(store.load(profile: "owner") == hidden("home.ondeck"))
        #expect(store.load(profile: "isabel") == hidden("home.continue"))
        #expect(store.load(profile: "guest") == Prefs())
    }

    @Test func settingsChangedBeforeTheProfileWasKnownMoveToTheFirstProfileOnly() {
        store.save(hidden("home.ondeck"), profile: "")

        #expect(store.load(profile: "owner", inheriting: "") == hidden("home.ondeck"))
        #expect(store.load(profile: "owner") == hidden("home.ondeck"))
        #expect(store.load(profile: "isabel", inheriting: "") == Prefs())
    }

    @Test func aProfileNamedDifferentlyByPlexTVTakesTheSettingsKeptUnderTheOldName() {
        store.save(hidden("home.ondeck"), profile: "stale")

        #expect(store.load(profile: "fresh", inheriting: "stale") == hidden("home.ondeck"))
        #expect(store.load(profile: "fresh") == hidden("home.ondeck"))
    }

    @Test func anotherProfileNeverInheritsWithoutBeingTold() {
        store.save(hidden("home.ondeck"), profile: "owner")

        #expect(store.load(profile: "isabel") == Prefs())
    }

    @Test func storedSettingsWinOverInheritedOnes() {
        store.save(hidden("home.ondeck"), profile: "stale")
        store.save(hidden("home.continue"), profile: "fresh")

        #expect(store.load(profile: "fresh", inheriting: "stale") == hidden("home.continue"))
    }

    @Test func aBlobThatDoesNotDecodeGivesDefaultsAndTheNextSaveReplacesIt() {
        blobs.data["settings.owner"] = Data("not json".utf8)

        #expect(store.load(profile: "owner") == Prefs())
        store.save(hidden("home.ondeck"), profile: "owner")
        #expect(store.load(profile: "owner") == hidden("home.ondeck"))
    }
}
