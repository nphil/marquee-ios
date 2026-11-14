import Foundation
import MarqueeCore

/// This iPhone's link id and its linked phones with their keys, in the Keychain under a service of its
/// own; UI-test launches keep them in memory.
@MainActor
final class LinkStore {
    struct Vault: Codable {
        var id: LinkID
        var phones: [LinkedPhone]
    }

    private static let key = "link.vault"
    private let keychain: KeychainStore?
    private var memory: Vault?

    init(inMemory: Bool) {
        keychain = inMemory ? nil : KeychainStore(service: "com.nphil.marquee.link")
    }

    /// The saved vault, or a new id with no phones the first time. Nil when the Keychain cannot be read
    /// yet, so a locked phone never replaces the links it has.
    func load() -> Vault? {
        guard let keychain else {
            if memory == nil { memory = Vault(id: .random(), phones: []) }
            return memory
        }
        do {
            if let data = try keychain.data(for: Self.key), let vault = try? JSONDecoder().decode(Vault.self, from: data) {
                return vault
            }
        } catch {
            return nil
        }
        let vault = Vault(id: .random(), phones: [])
        save(vault)
        return vault
    }

    func save(_ vault: Vault) {
        guard let keychain else {
            memory = vault
            return
        }
        guard let data = try? JSONEncoder().encode(vault) else { return }
        try? keychain.setData(data, for: Self.key)
    }

    func erase() {
        memory = nil
        try? keychain?.setData(nil, for: Self.key)
    }
}
