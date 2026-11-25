import Foundation

/// What a backup takes from a device, and how to tell whether anything changed since the last one.
public enum BackupSnapshot {
    /// Every entry the scope covers in a fixed order, with the integrations the other platform can apply.
    public static func make(
        from store: some BackupStore, platform: String, appVersion: String, scope: BackupScope = .phone
    ) throws -> BackupPayload {
        let entries = try store.read().filter(scope.covers).sorted { $0.id < $1.id }
        let integrations = platform == BackupPlatform.ios ? BackupScope.integrations(fromPhone: entries) : [:]
        return BackupPayload(platform: platform, appVersion: appVersion, entries: entries, integrations: integrations)
    }

    /// A SHA-256 over what is backed up, not over when or by which version, so settings that did not change
    /// need no new file. Meant to be held in memory only: it is a hash of secrets.
    public static func fingerprint(_ payload: BackupPayload) -> Data {
        struct Content: Encodable {
            var entries: [BackupEntry]
            var integrations: BackupIntegrations
        }
        let encoder = BackupContainer.encoder()
        let bytes = (try? encoder.encode(Content(entries: payload.entries, integrations: payload.integrations))) ?? Data()
        return BackupCrypto.sha256(bytes)
    }
}
