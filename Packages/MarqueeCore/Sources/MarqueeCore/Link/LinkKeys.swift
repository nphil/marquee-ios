#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The link's keys, each HKDF-SHA256 (RFC 5869) under its own label, so no key serves two purposes.
///
/// Pairing runs a Noise NNpsk0 handshake keyed by `pairingKey` of the code's secret; inside it each
/// phone sends a random share, and both keep `linkKey` of the two shares. Every later session runs the
/// same handshake keyed by `sessionKey`; its fresh ephemeral keys give each session keys of its own.
public enum LinkKeys {
    public static let keyLength = 32
    public static let shareLength = 32
    static let salt = Data("Marquee phone link v1".utf8)

    /// The pairing handshake's pre-shared key, from the secret in the code.
    public static func pairingKey(secret: Data) -> Data {
        derive(secret, salt: salt, info: Data("pairing".utf8))
    }

    /// The key two linked phones keep. The phone that showed the code is the inviter; both phones pass
    /// the same arguments, so both get the same key.
    public static func linkKey(secret: Data, inviter: LinkID, inviterShare: Data, guest: LinkID, guestShare: Data) -> Data {
        derive(inviterShare + guestShare, salt: secret, info: Data("link".utf8) + inviter.bytes + guest.bytes)
    }

    /// The pre-shared key of each session between linked phones.
    public static func sessionKey(linkKey: Data) -> Data {
        derive(linkKey, salt: salt, info: Data("session".utf8))
    }

    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func derive(_ material: Data, salt: Data, info: Data, length: Int = keyLength) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material), salt: salt, info: info, outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
