import Foundation

/// A backup that was opened: what it holds and who made it.
public struct OpenedBackup: Sendable {
    public let header: BackupHeader
    public let payload: BackupPayload
    /// Set when the recovery passphrase opened the file, to be kept with `BackupKeyring.adopt`.
    public let passphraseKey: BackupKeyring.PassphraseKey?
}

/// Making and opening backup files (DESIGN §8.13). Opening with a passphrase runs the stretching function
/// (about a second), so it belongs off the main thread.
public enum Backup {
    /// Seals `payload` for `account`: an `account` slot always, and a `passphrase` slot when the keyring has one.
    public static func seal(_ payload: BackupPayload, account: String, keyring: BackupKeyring, now: Date = Date()) throws -> Data {
        let dataKey = BackupCrypto.random(BackupCrypto.keyLength)
        let digest = BackupAccount.digest(account)

        var slots = [try slot(
            type: BackupHeader.Slot.account, key: keyring.accountKey(for: account), dataKey: dataKey, account: digest,
            kid: keyring.keyID, passphrase: nil
        )]
        if let passphrase = keyring.passphrase {
            slots.append(try slot(
                type: BackupHeader.Slot.passphrase, key: passphrase.key, dataKey: dataKey, account: digest,
                kid: nil, passphrase: passphrase
            ))
        }
        let header = BackupHeader(
            format: BackupFormat.name, version: BackupFormat.version, createdAt: Int(now.timeIntervalSince1970),
            app: .init(platform: payload.platform, version: payload.appVersion), account: digest,
            cipher: BackupFormat.cipher, slots: slots
        )
        let encoder = BackupContainer.encoder()
        let headerBytes = try encoder.encode(header)
        let authenticated = BackupContainer.preamble(version: BackupFormat.version, headerLength: headerBytes.count) + headerBytes
        return try authenticated + BackupCrypto.seal(try encoder.encode(payload), key: dataKey, authenticating: authenticated)
    }

    /// The header alone: when, by which app and for whom. Needs no key.
    public static func inspect(_ file: Data) throws -> BackupHeader {
        try BackupContainer.parse(file).header
    }

    /// Whether the file was made for `account`.
    public static func belongs(_ header: BackupHeader, to account: String) -> Bool {
        header.account == BackupAccount.digest(account)
    }

    /// Opens `file` for `account` with the keyring's account key when the file was made with it, else with
    /// `passphrase`. The checks come in this order, each with its own error: not a backup, damaged, newer,
    /// another account, no way in, wrong passphrase, and damaged again once the key was right.
    public static func open(_ file: Data, account: String, keyring: BackupKeyring?, passphrase: String? = nil) throws -> OpenedBackup {
        let parsed = try BackupContainer.parse(file)
        guard belongs(parsed.header, to: account) else { throw BackupError.wrongAccount }

        var dataKey: Data?
        var adopted: BackupKeyring.PassphraseKey?
        if let keyring, let slot = parsed.header.slots.first(where: { $0.type == BackupHeader.Slot.account && $0.kid == keyring.keyID }) {
            guard let key = unwrap(slot, key: keyring.accountKey(for: account), account: parsed.header.account) else {
                throw BackupError.damaged
            }
            dataKey = key
        } else if let slot = parsed.header.slots.first(where: { $0.type == BackupHeader.Slot.passphrase }) {
            guard let passphrase else { throw BackupError.needsPassphrase }
            guard slot.kdf == BackupFormat.kdf, let salt = slot.kdfSalt, let rounds = slot.iterations,
                  (1...BackupFormat.maxIterations).contains(rounds) else { throw BackupError.damaged }
            let stretched = BackupCrypto.pbkdf2(password: Data(BackupKeyring.normalise(passphrase).utf8), salt: salt, iterations: rounds)
            guard let key = unwrap(slot, key: stretched, account: parsed.header.account) else { throw BackupError.wrongPassphrase }
            dataKey = key
            adopted = .init(salt: salt, iterations: rounds, key: stretched)
        } else {
            throw BackupError.keyNotOnThisDevice
        }

        guard let dataKey,
              let plaintext = BackupCrypto.open(parsed.sealed, key: dataKey, authenticating: parsed.authenticated),
              let payload = try? JSONDecoder().decode(BackupPayload.self, from: plaintext) else {
            throw BackupError.damaged
        }
        return OpenedBackup(header: parsed.header, payload: payload, passphraseKey: adopted)
    }

    // MARK: Slots

    private static func slot(
        type: String, key: Data, dataKey: Data, account: Data, kid: String?, passphrase: BackupKeyring.PassphraseKey?
    ) throws -> BackupHeader.Slot {
        let wrapSalt = BackupCrypto.random(32)
        return BackupHeader.Slot(
            type: type, kid: kid,
            kdf: passphrase.map { _ in BackupFormat.kdf }, iterations: passphrase?.iterations, kdfSalt: passphrase?.salt,
            wrapSalt: wrapSalt,
            wrapped: try BackupCrypto.seal(
                dataKey, key: wrapKey(key, salt: wrapSalt, type: type), authenticating: wrapContext(type: type, account: account)
            )
        )
    }

    static func unwrap(_ slot: BackupHeader.Slot, key: Data, account: Data) -> Data? {
        BackupCrypto.open(
            slot.wrapped, key: wrapKey(key, salt: slot.wrapSalt, type: slot.type),
            authenticating: wrapContext(type: slot.type, account: account)
        )
    }

    private static func wrapKey(_ key: Data, salt: Data, type: String) -> Data {
        BackupCrypto.hkdf(key, salt: salt, info: Data("wrap\0\(type)".utf8))
    }

    private static func wrapContext(type: String, account: Data) -> Data {
        Data("marquee.backup.v1.slot\0\(type)\0".utf8) + account
    }
}
