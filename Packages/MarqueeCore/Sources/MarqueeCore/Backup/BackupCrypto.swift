#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The primitives a backup file is made of: ChaCha20-Poly1305 (RFC 8439) for the payload and the key
/// slots, HKDF-SHA256 (RFC 5869) for every derived key, and PBKDF2-HMAC-SHA256 (RFC 8018) for the
/// recovery passphrase. Neither CryptoKit nor swift-crypto ships PBKDF2, so it is built here from HMAC and
/// checked against published vectors.
enum BackupCrypto {
    static let keyLength = 32
    static let nonceLength = 12
    static let tagLength = 16

    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hkdf(_ material: Data, salt: Data, info: Data, length: Int = keyLength) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: info, outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// `nonce ‖ ciphertext ‖ tag`, with a fresh random nonce.
    static func seal(_ plaintext: Data, key: Data, authenticating aad: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad).combined
    }

    /// Nil when the key is wrong or anything, the associated data included, was changed.
    static func open(_ combined: Data, key: Data, authenticating aad: Data) -> Data? {
        guard combined.count >= nonceLength + tagLength,
              let box = try? ChaChaPoly.SealedBox(combined: combined) else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    /// PBKDF2 with HMAC-SHA256. The keyed HMAC is set up once and copied for each round, so a round costs
    /// two compressions instead of four.
    static func pbkdf2(password: Data, salt: Data, iterations: Int, length: Int = keyLength) -> Data {
        precondition(iterations >= 1 && length >= 1)
        let template = HMAC<SHA256>(key: SymmetricKey(data: password))
        var derived = Data()
        for block in 1...((length + 31) / 32) {
            var first = template
            first.update(data: salt)
            first.update(data: Data([UInt8(truncatingIfNeeded: block >> 24), UInt8(truncatingIfNeeded: block >> 16),
                                     UInt8(truncatingIfNeeded: block >> 8), UInt8(truncatingIfNeeded: block)]))
            var round = [UInt8](repeating: 0, count: 32)
            var total = [UInt8](repeating: 0, count: 32)
            first.finalize().withUnsafeBytes { bytes in
                for index in 0..<32 {
                    round[index] = bytes[index]
                    total[index] = bytes[index]
                }
            }
            for _ in 1..<iterations {
                var mac = template
                mac.update(data: round)
                mac.finalize().withUnsafeBytes { bytes in
                    for index in 0..<32 {
                        round[index] = bytes[index]
                        total[index] ^= bytes[index]
                    }
                }
            }
            derived.append(contentsOf: total)
        }
        return derived.prefix(length)
    }
}
