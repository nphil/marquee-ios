import Foundation

/// Which Plex account a backup belongs to. Switching profile replaces the token the app holds, so the
/// profile's own id is not stable; the Plex Home's admin is, whichever profile is active.
public enum BackupAccount {
    /// The id to seal and open backups under, or nil before the account is known.
    public static func id(user: PlexHomeUser?, homeUsers: [PlexHomeUser]) -> String? {
        guard let owner = homeUsers.first(where: \.isAdmin) ?? user else { return nil }
        return id(uuid: owner.uuid, number: owner.id)
    }

    /// The same id from the two fields Plex gives an account, for callers without a `PlexHomeUser`.
    public static func id(uuid: String?, number: Int?) -> String? {
        if let uuid, !uuid.isEmpty { return "uuid:\(uuid.lowercased())" }
        if let number, number > 0 { return "id:\(number)" }
        return nil
    }

    static func digest(_ account: String) -> Data {
        BackupCrypto.sha256(Data("marquee.backup.account.v1\0\(account)".utf8))
    }
}

/// What opens this device's backups, kept in one secure item per account (the iCloud Keychain on the
/// iPhone, Keystore-protected storage on Android): a random secret, and the key stretched from the
/// recovery passphrase once so automatic backups never ask for it. Neither leaves the secure item.
public struct BackupKeyring: Codable, Equatable, Sendable {
    public var secret: Data
    public var passphrase: PassphraseKey?

    /// A passphrase after PBKDF2: what the file's `passphrase` slot is wrapped under.
    public struct PassphraseKey: Codable, Equatable, Sendable {
        public var salt: Data
        public var iterations: Int
        public var key: Data

        public init(salt: Data, iterations: Int, key: Data) {
            self.salt = salt
            self.iterations = iterations
            self.key = key
        }
    }

    public init(secret: Data, passphrase: PassphraseKey? = nil) {
        self.secret = secret
        self.passphrase = passphrase
    }

    public static func create() -> BackupKeyring {
        BackupKeyring(secret: BackupCrypto.random(BackupCrypto.keyLength))
    }

    public var hasPassphrase: Bool { passphrase != nil }

    /// A short fingerprint of the secret, written into the account slot so a file made with another
    /// secret is told apart from a damaged one.
    public var keyID: String {
        BackupCrypto.hkdf(secret, salt: Data("marquee.backup.v1".utf8), info: Data("kid".utf8), length: 8)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Stretches `phrase` into this keyring's passphrase key, with a new salt. Backups made earlier keep
    /// the passphrase they were made with.
    public mutating func setPassphrase(_ phrase: String) throws {
        try setPassphrase(phrase, iterations: BackupFormat.passphraseIterations)
    }

    mutating func setPassphrase(_ phrase: String, iterations: Int) throws {
        let text = Self.normalise(phrase)
        guard text.count >= BackupFormat.minPassphraseLength else { throw BackupError.passphraseTooShort }
        guard text.count <= BackupFormat.maxPassphraseLength else { throw BackupError.passphraseTooLong }
        let salt = BackupCrypto.random(16)
        passphrase = PassphraseKey(
            salt: salt, iterations: iterations,
            key: BackupCrypto.pbkdf2(password: Data(text.utf8), salt: salt, iterations: iterations)
        )
    }

    public mutating func removePassphrase() {
        passphrase = nil
    }

    /// Keeps the passphrase key that just opened a backup, so backups made from here on carry the same
    /// passphrase without asking for it again.
    public mutating func adopt(_ key: PassphraseKey?) {
        if passphrase == nil, let key { passphrase = key }
    }

    /// NFKC, so the same words typed on another keyboard or system give the same key; nothing is trimmed.
    /// Opening a file applies no length rule: only a new passphrase has to meet the current one.
    static func normalise(_ phrase: String) -> String {
        phrase.precomposedStringWithCompatibilityMapping
    }

    /// The key every account slot is wrapped under: HKDF of the secret, with the account id as context.
    func accountKey(for account: String) -> Data {
        BackupCrypto.hkdf(
            secret, salt: Data("marquee.backup.v1".utf8), info: Data("account\0\(account)".utf8)
        )
    }
}
