import Foundation
import LumaRemoteCore
import MarqueeCore

/// The iPhone's storage as a backup sees it: Marquee's preferences, the remote's, the Keychain secrets the
/// scope names and the paired TVs. `BackupScope.phone` decides what is covered; this only reads and writes it.
/// `UserDefaults` is documented as safe to use from any thread, which is what the unchecked conformance rests on.
struct PhoneBackupStore: BackupStore, @unchecked Sendable {
    /// A value this iPhone cannot take. A restore stops on it before anything is written.
    struct Unsupported: Error {}

    private typealias Phone = BackupScope.Phone

    let defaults: UserDefaults
    let domain: String
    let remoteSuite: String
    /// Nil in UI tests, which keep their secrets in memory and have none to back up.
    let keychain: KeychainStore?
    let pairings: any PairingStore

    func read() throws -> [BackupEntry] {
        let scope = BackupScope.phone
        var entries: [BackupEntry] = []

        for (store, name) in [(Phone.defaults, domain), (Phone.remote, remoteSuite)] {
            guard let target = target(for: store) else { continue }
            for (key, raw) in target.persistentDomain(forName: name) ?? [:] {
                guard let kind = scope.classify(store: store, key: key) else { continue }
                let value = kind.isURL ? target.url(forKey: key).map { BackupValue.string($0.absoluteString) } : Self.value(raw)
                guard let value else { continue }
                entries.append(BackupEntry(store: store, key: key, group: kind.group, item: kind.item, value: value))
            }
        }

        if let keychain {
            for key in scope.keys(in: Phone.secret) {
                guard let text = try keychain.string(for: key),
                      let kind = scope.classify(store: Phone.secret, key: key)
                else { continue }
                entries.append(BackupEntry(store: Phone.secret, key: key, group: kind.group, item: kind.item, value: .string(text)))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tv in try pairings.all() {
            entries.append(BackupEntry(
                store: Phone.tv, key: tv.id.description, group: .tvs, item: tv.name, value: .data(try encoder.encode(tv))
            ))
        }
        return entries
    }

    func validate(_ entry: BackupEntry) throws {
        switch entry.store {
        case Phone.defaults, Phone.remote:
            guard target(for: entry.store) != nil else { throw Unsupported() }
            if isURL(entry) { _ = try url(in: entry) }
        case Phone.secret:
            guard keychain != nil, case .string = entry.value else { throw Unsupported() }
        case Phone.tv:
            _ = try Self.tv(in: entry)
        default:
            throw Unsupported()
        }
    }

    func write(_ entry: BackupEntry) throws {
        switch entry.store {
        case Phone.defaults, Phone.remote:
            guard let target = target(for: entry.store) else { throw Unsupported() }
            switch entry.value {
            case .bool(let value): target.set(value, forKey: entry.key)
            case .int(let value): target.set(value, forKey: entry.key)
            case .double(let value): target.set(value, forKey: entry.key)
            case .string(let value):
                if isURL(entry) {
                    try target.set(url(in: entry), forKey: entry.key)
                } else {
                    target.set(value, forKey: entry.key)
                }
            case .strings(let value): target.set(value, forKey: entry.key)
            case .data(let value): target.set(value, forKey: entry.key)
            }
        case Phone.secret:
            guard let keychain, case .string(let text) = entry.value else { throw Unsupported() }
            try keychain.setString(text, for: entry.key)
        case Phone.tv:
            try pairings.save(Self.tv(in: entry))
        default:
            throw Unsupported()
        }
    }

    func remove(_ entry: BackupEntry) throws {
        switch entry.store {
        case Phone.defaults, Phone.remote:
            target(for: entry.store)?.removeObject(forKey: entry.key)
        case Phone.secret:
            try keychain?.setString(nil, for: entry.key)
        case Phone.tv:
            guard let id = TVID(entry.key) else { throw Unsupported() }
            try pairings.remove(id)
        default:
            throw Unsupported()
        }
    }

    private func target(for store: String) -> UserDefaults? {
        store == Phone.remote ? UserDefaults(suiteName: remoteSuite) : defaults
    }

    private func isURL(_ entry: BackupEntry) -> Bool {
        BackupScope.phone.classify(store: entry.store, key: entry.key)?.isURL == true
    }

    private func url(in entry: BackupEntry) throws -> URL {
        guard case .string(let text) = entry.value, let url = URL(string: text) else { throw Unsupported() }
        return url
    }

    private static func tv(in entry: BackupEntry) throws -> PairedTV {
        guard case .data(let data) = entry.value else { throw Unsupported() }
        let tv = try JSONDecoder().decode(PairedTV.self, from: data)
        guard tv.id.description == entry.key else { throw Unsupported() }
        return tv
    }

    /// What `UserDefaults` hands back for a plist value, in the types a backup carries. Anything else is left out.
    private static func value(_ raw: Any) -> BackupValue? {
        switch raw {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number as CFNumber) ? .double(number.doubleValue) : .int(number.intValue)
        case let text as String: return .string(text)
        case let list as [String]: return .strings(list)
        case let data as Data: return .data(data)
        default: return nil
        }
    }
}
