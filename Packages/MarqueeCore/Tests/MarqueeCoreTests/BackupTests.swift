import Foundation
import Testing
@testable import MarqueeCore

private let account = "uuid:3f2a9c1e5b7d4a60"
private let phrase = "correct horse battery staple"

/// Few rounds: the stretching is checked against published vectors, so tests need not pay for 600 000.
private func keyring(passphrase: Bool = false) throws -> BackupKeyring {
    var keyring = BackupKeyring.create()
    if passphrase { try keyring.setPassphrase(phrase, iterations: 1_000) }
    return keyring
}

private func samplePayload() -> BackupPayload {
    BackupPayload(platform: BackupPlatform.ios, appVersion: "0.1.68", entries: [
        BackupEntry(store: "defaults", key: "marquee.theme.dark", group: .appearance, value: .string("rose-pine-moon")),
        BackupEntry(store: "defaults", key: "marquee.tabs", group: .tabs, value: .strings(["home", "library"])),
        BackupEntry(store: "defaults", key: "marquee.diag.live", group: .integrations, item: "Diagnostic Logs", value: .bool(true)),
        BackupEntry(store: "defaults", key: "marquee.remote.dock", group: .remote, value: .int(3)),
        BackupEntry(store: "defaults", key: "marquee.glasses.tilt", group: .bigScreen, value: .double(0.25)),
        BackupEntry(store: "defaults", key: "marquee.settings.a", group: .profiles, value: .data(Data([0, 1, 2, 255]))),
        BackupEntry(store: "secret", key: "marquee.bazarr.key", group: .integrations, item: "Bazarr", value: .string("hunter2-api-key")),
    ], integrations: [BackupIntegrationName.bazarr: BackupIntegration(address: "https://bazarr.example", secret: "hunter2-api-key")])
}

/// Rebuilds a valid file around `edit`ed header fields and an optional replacement payload, using the data
/// key the account slot hands over: what a newer writer's file would look like to this reader.
private func forged(
    from file: Data, keyring: BackupKeyring, payload: Data? = nil, header edit: (inout [String: Any]) -> Void
) throws -> Data {
    let parsed = try BackupContainer.parse(file)
    let slot = try #require(parsed.header.slots.first { $0.type == "account" })
    let dataKey = try #require(Backup.unwrap(slot, key: keyring.accountKey(for: account), account: parsed.header.account))
    let headerJSON = parsed.authenticated.subdata(in: BackupFormat.preambleLength..<parsed.authenticated.count)
    var object = try #require(JSONSerialization.jsonObject(with: headerJSON) as? [String: Any])
    edit(&object)
    let headerBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let authenticated = BackupContainer.preamble(version: 1, headerLength: headerBytes.count) + headerBytes
    let plaintext = try payload ?? #require(BackupCrypto.open(parsed.sealed, key: dataKey, authenticating: parsed.authenticated))
    return try authenticated + BackupCrypto.seal(plaintext, key: dataKey, authenticating: authenticated)
}

struct BackupFileTests {
    @Test func theAccountKeyOpensItAndEveryEntryComesBack() throws {
        let keys = try keyring()
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys, now: Date(timeIntervalSince1970: 1_764_000_000))
        let opened = try Backup.open(file, account: account, keyring: keys)
        #expect(opened.payload == samplePayload())
        #expect(opened.header.createdAt == 1_764_000_000)
        #expect(opened.header.app == .init(platform: "ios", version: "0.1.68"))
        #expect(opened.header.hasPassphraseSlot == false)
        #expect(opened.passphraseKey == nil)
        #expect(try Backup.inspect(file) == opened.header)
        #expect(file.prefix(4) == Data("MQBK".utf8))
    }

    @Test func nothingItProtectsIsReadableInTheFile() throws {
        let file = try Backup.seal(samplePayload(), account: account, keyring: keyring(passphrase: true))
        for secret in ["hunter2-api-key", "rose-pine-moon", "bazarr.example", "3f2a9c1e5b7d4a60", "marquee.theme", phrase] {
            #expect(file.range(of: Data(secret.utf8)) == nil, "\(secret)")
        }
    }

    @Test func eachFileHasItsOwnKeyAndNonce() throws {
        let keys = try keyring()
        let first = try Backup.seal(samplePayload(), account: account, keyring: keys)
        let second = try Backup.seal(samplePayload(), account: account, keyring: keys)
        #expect(first != second)
        #expect(try Backup.inspect(first).slots[0].wrapped != Backup.inspect(second).slots[0].wrapped)
    }

    @Test func aChangedHeaderIsRefused() throws {
        let keys = try keyring()
        var file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        let at = try #require(file.range(of: Data("\"createdAt\":".utf8))).upperBound
        file[at] = file[at] == UInt8(ascii: "1") ? UInt8(ascii: "2") : UInt8(ascii: "1")
        #expect(throws: BackupError.damaged) { try Backup.open(file, account: account, keyring: keys) }
    }

    @Test func aChangedPayloadIsRefused() throws {
        let keys = try keyring()
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        for offset in [1, 20, 100] {
            var changed = file
            changed[changed.count - offset] ^= 0x01
            #expect(throws: BackupError.damaged) { try Backup.open(changed, account: account, keyring: keys) }
        }
    }

    @Test func aChangedKeySlotIsRefused() throws {
        let keys = try keyring()
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        let parsed = try BackupContainer.parse(file)
        let wrapped = try #require(parsed.header.slots.first?.wrapped)
        var changed = wrapped
        changed[changed.count - 1] ^= 0x01
        let edited = try forged(from: file, keyring: keys) { object in
            var slots = object["slots"] as? [[String: Any]] ?? []
            slots[0]["wrapped"] = changed.base64EncodedString()
            object["slots"] = slots
        }
        #expect(throws: BackupError.damaged) { try Backup.open(edited, account: account, keyring: keys) }
    }

    @Test func aFileThatIsNotABackupOrIsCutShortSaysSo() throws {
        let keys = try keyring()
        #expect(throws: BackupError.notABackup) { try Backup.open(Data("hello".utf8), account: account, keyring: keys) }
        #expect(throws: BackupError.notABackup) { try Backup.open(Data(), account: account, keyring: keys) }
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        for length in [4, 11, 12, 40, file.count - 1] {
            #expect(throws: BackupError.damaged) { try Backup.open(file.prefix(length), account: account, keyring: keys) }
        }
    }

    @Test func anotherAccountIsRefusedBeforeAnyKeyIsTried() throws {
        let keys = try keyring(passphrase: true)
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        #expect(throws: BackupError.wrongAccount) { try Backup.open(file, account: "uuid:someone-else", keyring: keys) }
        #expect(throws: BackupError.wrongAccount) { try Backup.open(file, account: "uuid:someone-else", keyring: nil, passphrase: phrase) }
        #expect(Backup.belongs(try Backup.inspect(file), to: account))
        #expect(!Backup.belongs(try Backup.inspect(file), to: "uuid:someone-else"))
    }

    @Test func aNewerVersionIsRefusedNotGuessedAt() throws {
        let keys = try keyring()
        var file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        file[4] = 0
        file[5] = 2
        #expect(throws: BackupError.newerVersion(2)) { try Backup.open(file, account: account, keyring: keys) }
        #expect(throws: BackupError.newerVersion(2)) { try Backup.inspect(file) }
    }

    @Test func fieldsAndKindsThisVersionDoesNotKnowAreIgnored() throws {
        let keys = try keyring()
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        let payload = Data("""
        {"platform":"ios","appVersion":"9.9","tomorrow":{"x":1},"entries":[
          {"store":"defaults","key":"marquee.tabs","group":"tabs","kind":"strings","value":["a"],"later":true},
          {"store":"defaults","key":"marquee.new","group":"newer","kind":"matrix","value":[[1,2],[3,4]]},
          {"store":"defaults","key":"marquee.theme.dark","kind":"string","value":"x"}],
         "integrations":{"seerr":{"address":"https://s.example","extra":1},"future":{"address":"https://f.example"},"broken":7}}
        """.utf8)
        let edited = try forged(from: file, keyring: keys, payload: payload) { object in
            object["tomorrow"] = ["a": 1]
            object["slots"] = (object["slots"] as? [[String: Any]] ?? []) + [["type": "hardware", "wrapSalt": "AA==", "wrapped": "AA=="]]
        }
        let opened = try Backup.open(edited, account: account, keyring: keys)
        #expect(opened.payload.entries.map(\.key) == ["marquee.tabs", "marquee.theme.dark"])
        #expect(opened.payload.entries[1].group == .other)
        #expect(opened.payload.integrations["seerr"]?.address == "https://s.example")
        #expect(opened.payload.integrations["future"] != nil)
        #expect(opened.payload.integrations["broken"] == nil)
        #expect(opened.payload.appVersion == "9.9")
    }
}

struct BackupPassphraseTests {
    @Test func thePassphraseOpensItWithoutTheAccountSecret() throws {
        let keys = try keyring(passphrase: true)
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        #expect(try Backup.inspect(file).hasPassphraseSlot)

        // A new device: no keyring at all, or one with another secret.
        for stranger in [nil, try keyring()] {
            let opened = try Backup.open(file, account: account, keyring: stranger, passphrase: phrase)
            #expect(opened.payload == samplePayload())
            #expect(opened.passphraseKey == keys.passphrase)
        }
    }

    @Test func aWrongOrMissingPassphraseEachHaveTheirOwnError() throws {
        let keys = try keyring(passphrase: true)
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        #expect(throws: BackupError.needsPassphrase) { try Backup.open(file, account: account, keyring: nil) }
        #expect(throws: BackupError.wrongPassphrase) { try Backup.open(file, account: account, keyring: nil, passphrase: "not the right words") }
        #expect(throws: BackupError.wrongPassphrase) { try Backup.open(file, account: account, keyring: nil, passphrase: "short") }
    }

    @Test func aFileWithoutAPassphraseSlotNeedsTheKeyItWasMadeWith() throws {
        let file = try Backup.seal(samplePayload(), account: account, keyring: keyring())
        #expect(throws: BackupError.keyNotOnThisDevice) { try Backup.open(file, account: account, keyring: nil, passphrase: phrase) }
        #expect(throws: BackupError.keyNotOnThisDevice) { try Backup.open(file, account: account, keyring: keyring(), passphrase: phrase) }
    }

    @Test func theKeyThatOpenedAFileIsKeptSoLaterBackupsCarryThePassphrase() throws {
        let original = try keyring(passphrase: true)
        let file = try Backup.seal(samplePayload(), account: account, keyring: original)
        var fresh = BackupKeyring.create()
        let opened = try Backup.open(file, account: account, keyring: fresh, passphrase: phrase)
        fresh.adopt(opened.passphraseKey)
        #expect(fresh.passphrase == original.passphrase)

        let later = try Backup.seal(samplePayload(), account: account, keyring: fresh)
        #expect(try Backup.open(later, account: account, keyring: nil, passphrase: phrase).payload == samplePayload())
        // The account key of the new keyring opens it too, and only that key does.
        #expect(try Backup.open(later, account: account, keyring: fresh).payload == samplePayload())
        #expect(throws: BackupError.needsPassphrase) { try Backup.open(later, account: account, keyring: BackupKeyring.create()) }
    }

    @Test func aNewPassphraseDoesNotOpenOlderBackups() throws {
        var keys = try keyring(passphrase: true)
        let old = try Backup.seal(samplePayload(), account: account, keyring: keys)
        try keys.setPassphrase("a completely different phrase", iterations: 1_000)
        let new = try Backup.seal(samplePayload(), account: account, keyring: keys)
        #expect(throws: BackupError.wrongPassphrase) { try Backup.open(old, account: account, keyring: nil, passphrase: "a completely different phrase") }
        #expect(try Backup.open(new, account: account, keyring: nil, passphrase: "a completely different phrase").payload == samplePayload())
    }

    @Test func passphrasesAreNormalisedAndMustBeLongEnough() throws {
        #expect(BackupKeyring.normalise("cafe\u{301} au lait") == "caf\u{e9} au lait")
        #expect(BackupKeyring.normalise("\u{ff21}\u{ff22}\u{ff23}") == "ABC")

        var keys = BackupKeyring.create()
        #expect(throws: BackupError.passphraseTooShort) { try keys.setPassphrase("eleven char") }
        #expect(throws: BackupError.passphraseTooLong) { try keys.setPassphrase(String(repeating: "x", count: 257)) }
        try keys.setPassphrase("caf\u{e9} au lait demain", iterations: 1_000)
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        let typedOnAnotherKeyboard = "cafe\u{301} au lait demain"
        #expect(try Backup.open(file, account: account, keyring: nil, passphrase: typedOnAnotherKeyboard).payload == samplePayload())
    }

    @Test func aHeaderThatAsksForAnAbsurdRoundCountIsRefusedAtOnce() throws {
        let keys = try keyring(passphrase: true)
        let file = try Backup.seal(samplePayload(), account: account, keyring: keys)
        for rounds in [0, BackupFormat.maxIterations + 1] {
            let edited = try forged(from: file, keyring: keys) { object in
                var slots = object["slots"] as? [[String: Any]] ?? []
                for index in slots.indices where slots[index]["type"] as? String == "passphrase" { slots[index]["iterations"] = rounds }
                object["slots"] = slots
            }
            #expect(throws: BackupError.damaged) { try Backup.open(edited, account: account, keyring: nil, passphrase: phrase) }
        }
    }

    @Test func theNewPassphraseUsesAtLeastTheRoundsOwaspAsksFor() {
        #expect(BackupFormat.passphraseIterations >= 600_000)
    }

    @Test func pbkdf2MatchesThePublishedVectors() {
        func derive(_ password: String, _ salt: String, _ rounds: Int, _ length: Int = 32) -> String {
            BackupCrypto.pbkdf2(password: Data(password.utf8), salt: Data(salt.utf8), iterations: rounds, length: length)
                .map { String(format: "%02x", $0) }.joined()
        }
        #expect(derive("password", "salt", 1) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(derive("password", "salt", 2) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        #expect(derive("password", "salt", 4096) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        // RFC 7914 §11, two output blocks.
        #expect(derive("passwd", "salt", 1, 64) == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    @Test func hkdfMatchesRFC5869() {
        // Test case 1.
        let key = BackupCrypto.hkdf(Data(repeating: 0x0b, count: 22), salt: Data(0..<13), info: Data(0xf0...0xf9), length: 42)
        #expect(key.map { String(format: "%02x", $0) }.joined() == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }
}
