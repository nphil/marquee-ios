import Foundation

/// The backup file (DESIGN §8.13): one file, `.marqueebackup`, that holds the settings and the secrets
/// of one Plex account, encrypted. Its layout, byte for byte:
///
///     "MQBK" · version u16 · flags u16 (0) · header length u32 (all big-endian) · header JSON · sealed payload
///
/// The sealed payload is `nonce ‖ ciphertext ‖ tag` of ChaCha20-Poly1305 under a random 256-bit data key,
/// with everything before it (preamble and header) as associated data, so no header byte can change
/// without the file being refused. The header says what the file is, when and by which app it was made, whose
/// it is (a hash of the Plex account) and the key slots: copies of the data key, each wrapped under a key
/// only one kind of owner can make. Fields a reader does not know are ignored; a version it does not know is
/// refused.
public enum BackupFormat {
    public static let fileExtension = "marqueebackup"
    public static let name = "marquee-backup"
    public static let version = 1

    /// PBKDF2-HMAC-SHA256 rounds for a new recovery passphrase (OWASP's floor for this function is 600 000).
    public static let passphraseIterations = 600_000
    /// The most rounds a file may ask for, so a forged header cannot keep a phone busy for hours.
    public static let maxIterations = 10_000_000
    public static let minPassphraseLength = 12
    public static let maxPassphraseLength = 256

    static let magic = Data("MQBK".utf8)
    static let preambleLength = 12
    static let maxHeaderLength = 64 * 1024
    static let cipher = "chacha20poly1305"
    static let kdf = "pbkdf2-hmac-sha256"

    /// `Marquee Backup 2026-11-25.marqueebackup`
    public static func fileName(on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Marquee Backup \(formatter.string(from: date)).\(fileExtension)"
    }
}

/// Why a backup could not be made or opened, each with the plain sentence to show.
public enum BackupError: Error, Equatable, Sendable {
    /// Not a Marquee backup at all.
    case notABackup
    /// Cut short, changed, or its contents unreadable.
    case damaged
    /// Written by a newer Marquee than this one.
    case newerVersion(Int)
    /// Made for another Plex account than the one signed in.
    case wrongAccount
    /// The account key cannot open it and the recovery passphrase has not been given.
    case needsPassphrase
    /// The account key cannot open it and the file has no recovery passphrase.
    case keyNotOnThisDevice
    case wrongPassphrase
    case passphraseTooShort
    case passphraseTooLong
    case noAccount
    /// Restoring failed and every change was undone.
    case restoreFailed
    /// Restoring failed and undoing the changes failed too.
    case restoreIncomplete

    public var message: String {
        switch self {
        case .notABackup: "That file is not a Marquee backup."
        case .damaged: "This backup is damaged or has been changed, so it cannot be restored."
        case .newerVersion: "This backup was made by a newer version of Marquee. Update Marquee, then open it again."
        case .wrongAccount: "This backup belongs to a different Plex account. Sign in with the account it was made with."
        case .needsPassphrase: "This backup was locked with a key this device does not have. Enter its recovery passphrase."
        case .keyNotOnThisDevice: "This backup was locked with a key this device does not have, and it has no recovery passphrase, so it cannot be restored here."
        case .wrongPassphrase: "That passphrase does not open this backup."
        case .passphraseTooShort: "Use at least \(BackupFormat.minPassphraseLength) characters. A few random words work well."
        case .passphraseTooLong: "Use at most \(BackupFormat.maxPassphraseLength) characters."
        case .noAccount: "Sign in to Plex first: a backup belongs to the Plex account it was made with."
        case .restoreFailed: "Restoring failed. Nothing was changed."
        case .restoreIncomplete: "Restoring failed and some settings could not be put back. Restore the backup again."
        }
    }
}

/// The readable part of a backup: enough to tell whose it is and what made it, with no key.
public struct BackupHeader: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    /// Unix seconds.
    public var createdAt: Int
    public var app: App
    /// SHA-256 of the Plex account id, so the file can be refused for another account without a key.
    public var account: Data
    public var cipher: String
    public var slots: [Slot]

    public struct App: Codable, Equatable, Sendable {
        /// `ios` or `android`.
        public var platform: String
        public var version: String

        public init(platform: String, version: String) {
            self.platform = platform
            self.version = version
        }
    }

    /// One way to get the data key. `account` is opened by a key made from the backup secret kept with the
    /// signed-in account; `passphrase` by a key stretched from the recovery passphrase.
    public struct Slot: Codable, Equatable, Sendable {
        public var type: String
        /// `account`: a fingerprint of the backup secret, to tell "another key" from "a damaged file".
        public var kid: String?
        /// `passphrase`: the function, its rounds and its salt.
        public var kdf: String?
        public var iterations: Int?
        public var kdfSalt: Data?
        /// Fresh for each file, so the key that wraps the data key is never used twice.
        public var wrapSalt: Data
        /// `nonce ‖ wrapped data key ‖ tag`.
        public var wrapped: Data
    }

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    public var hasPassphraseSlot: Bool { slots.contains { $0.type == Slot.passphrase } }
}

extension BackupHeader.Slot {
    static let account = "account"
    static let passphrase = "passphrase"
}

/// Reading and writing the bytes around the header and the sealed payload.
enum BackupContainer {
    struct Parsed {
        let header: BackupHeader
        /// Preamble and header exactly as stored: the associated data of the payload.
        let authenticated: Data
        let sealed: Data
    }

    static func parse(_ file: Data) throws -> Parsed {
        let bytes = [UInt8](file)
        let preamble = BackupFormat.preambleLength
        guard bytes.count >= BackupFormat.magic.count, Array(bytes[0..<BackupFormat.magic.count]) == Array(BackupFormat.magic) else {
            throw BackupError.notABackup
        }
        guard bytes.count > preamble else { throw BackupError.damaged }
        let version = Int(bytes[4]) << 8 | Int(bytes[5])
        guard version >= 1 else { throw BackupError.damaged }
        guard version <= BackupFormat.version else { throw BackupError.newerVersion(version) }
        let headerLength = bytes[8..<12].reduce(0) { $0 << 8 | Int($1) }
        guard headerLength >= 2, headerLength <= BackupFormat.maxHeaderLength,
              bytes.count >= preamble + headerLength + BackupCrypto.nonceLength + BackupCrypto.tagLength else {
            throw BackupError.damaged
        }
        let headerBytes = Data(bytes[preamble..<(preamble + headerLength)])
        guard let header = try? JSONDecoder().decode(BackupHeader.self, from: headerBytes),
              header.format == BackupFormat.name, header.version == version else {
            throw BackupError.damaged
        }
        return Parsed(
            header: header,
            authenticated: Data(bytes[0..<(preamble + headerLength)]),
            sealed: Data(bytes[(preamble + headerLength)...])
        )
    }

    static func preamble(version: Int, headerLength: Int) -> Data {
        var data = BackupFormat.magic
        data.append(contentsOf: [UInt8(version >> 8 & 0xff), UInt8(version & 0xff), 0, 0])
        data.append(contentsOf: [UInt8(headerLength >> 24 & 0xff), UInt8(headerLength >> 16 & 0xff),
                                 UInt8(headerLength >> 8 & 0xff), UInt8(headerLength & 0xff)])
        return data
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
