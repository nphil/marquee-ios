import Foundation
import MarqueeCore

/// Where the key that opens the account's backups lives: one Keychain item per Plex account.
///
/// It is a synchronizable item, which iCloud Keychain carries to the account's other iPhones when it is on, so
/// one iPhone can open another's backups. If the Keychain refuses a synchronizable item, a device-only item is
/// kept instead and `Home.deviceOnly` says so. Nothing here ever deletes the synchronizable item: a delete
/// reaches every iPhone and makes the backups they hold unopenable.
struct BackupKeyringStore: Sendable {
    enum Home: Sendable, Equatable {
        case synchronizable
        case deviceOnly
    }

    private enum Backing: Sendable {
        case keychain(shared: KeychainStore, local: KeychainStore)
        case memory(Memory)
    }

    private let backing: Backing

    static func live() -> BackupKeyringStore {
        BackupKeyringStore(backing: .keychain(
            shared: KeychainStore(service: "com.nphil.marquee.backup", synchronizable: true),
            local: KeychainStore(service: "com.nphil.marquee.backup.device")
        ))
    }

    /// For UI tests, which leave the Keychain alone.
    static func inMemory() -> BackupKeyringStore {
        BackupKeyringStore(backing: .memory(Memory()))
    }

    func load(account: String) throws -> (keyring: BackupKeyring, home: Home)? {
        let name = Self.name(account)
        switch backing {
        case .memory(let memory):
            guard let data = memory.get(name) else { return nil }
            return (try Self.decode(data), .deviceOnly)
        case .keychain(let shared, let local):
            if let data = try shared.data(for: name) { return (try Self.decode(data), .synchronizable) }
            if let data = try local.data(for: name) { return (try Self.decode(data), .deviceOnly) }
            return nil
        }
    }

    /// Where the key ended up: the synchronizable item when the Keychain takes it.
    @discardableResult
    func save(_ keyring: BackupKeyring, account: String) throws -> Home {
        let name = Self.name(account)
        let data = try JSONEncoder().encode(keyring)
        switch backing {
        case .memory(let memory):
            memory.set(name, data)
            return .deviceOnly
        case .keychain(let shared, let local):
            do {
                try shared.setData(data, for: name)
                try? local.setData(nil, for: name)
                return .synchronizable
            } catch {
                try local.setData(data, for: name)
                return .deviceOnly
            }
        }
    }

    private static func name(_ account: String) -> String { "keyring." + account }

    private static func decode(_ data: Data) throws -> BackupKeyring {
        try JSONDecoder().decode(BackupKeyring.self, from: data)
    }

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        func get(_ name: String) -> Data? { lock.withLock { items[name] } }
        func set(_ name: String, _ data: Data) { lock.withLock { items[name] = data } }
    }
}
