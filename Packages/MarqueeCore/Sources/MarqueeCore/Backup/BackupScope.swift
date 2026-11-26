import Foundation

public enum BackupPlatform {
    public static let ios = "ios"
    public static let android = "android"
}

/// What a backup covers on one device: every setting and every secret named here, and nothing else.
/// Settings are in by default and secrets out by default: a new key under `marquee.` is backed up, a new
/// Keychain item is not until it is added to `phoneSecrets`. The Plex sign-in, the Seerr session, the linked
/// phones' vault, downloads, caches and logs are never in it.
public struct BackupScope: Sendable {
    public struct Classification: Equatable, Sendable {
        public var group: BackupGroup
        public var item: String?
        /// The device keeps this value as a URL, which a backup carries as its string.
        public var isURL = false
    }

    struct Rule: Sendable {
        var store: String
        var key: String
        var isPrefix: Bool
        /// Nil leaves the key out.
        var classification: Classification?
    }

    var rules: [Rule]

    /// Where `key` in `store` belongs in a backup, or nil when a backup does not cover it. The first rule
    /// that matches decides.
    public func classify(store: String, key: String) -> Classification? {
        rules.first { $0.store == store && ($0.isPrefix ? key.hasPrefix($0.key) : key == $0.key) }?.classification
    }

    public func covers(_ entry: BackupEntry) -> Bool {
        classify(store: entry.store, key: entry.key) != nil
    }

    /// The items of `store` the scope names one by one, such as the Keychain secrets: they are looked up
    /// by name, so a secret is only ever backed up because it is listed here.
    public func keys(in store: String) -> [String] {
        rules.filter { $0.store == store && !$0.isPrefix && $0.classification != nil }.map(\.key)
    }
}

extension BackupScope {
    /// The iPhone's stores: `defaults` (Marquee's preferences), `remote` (the LumaRemoteKit suite), `secret`
    /// (Keychain items under `com.nphil.marquee`) and `tv` (paired TVs, one JSON entry each).
    public enum Phone {
        public static let defaults = "defaults"
        public static let remote = "remote"
        public static let secret = "secret"
        public static let tv = "tv"

        public static let seerrAddress = "marquee.seerr.address"
        public static let seerrKey = "marquee.seerr.key"
        public static let seerrPulsarr = "marquee.seerr.pulsarr"
        public static let radarrAddress = "marquee.radarr.address"
        public static let radarrKey = "marquee.radarr.key"
        public static let sonarrAddress = "marquee.sonarr.address"
        public static let sonarrKey = "marquee.sonarr.key"
        public static let bazarrAddress = "marquee.bazarr.address"
        public static let bazarrKey = "marquee.bazarr.key"
        public static let speechDockAddress = "marquee.speechDock.address"
        public static let homeLabberAddress = "marquee.homelabber.address"
        public static let homeLabberToken = "marquee.homelabber.token"
        public static let diagServer = "marquee.diag.server"
        public static let diagTopic = "marquee.diag.topic"
        public static let diagToken = "marquee.diag.token"
    }

    public static let phone: BackupScope = {
        func out(_ key: String, prefix: Bool = false) -> Rule {
            Rule(store: Phone.defaults, key: key, isPrefix: prefix, classification: nil)
        }
        func inn(_ key: String, _ group: BackupGroup, item: String? = nil, prefix: Bool = false, url: Bool = false) -> Rule {
            Rule(store: Phone.defaults, key: key, isPrefix: prefix, classification: .init(group: group, item: item, isURL: url))
        }
        func secret(_ key: String, _ item: String) -> Rule {
            Rule(store: Phone.secret, key: key, isPrefix: false, classification: .init(group: .integrations, item: item))
        }
        return BackupScope(rules: [
            // Left on the phone: caches, device state, test switches and the backup's own bookkeeping.
            out("marquee.server.address.", prefix: true), out("marquee.profile"), out("marquee.backup.", prefix: true),
            out("marquee.account.", prefix: true), out("marquee.link.", prefix: true), out("marquee.uitest.", prefix: true),
            out("marquee.fakeSignedIn"), out("marquee.fakeServerList"), out("marquee.downloads.backgroundBroken"),
            out("marquee.diag.name"), out("marquee.recordings.", prefix: true),

            inn("marquee.settings.", .profiles, prefix: true),
            inn("marquee.theme.", .appearance, prefix: true), inn("marquee.headerStyle", .appearance),
            inn("marquee.tabBar", .appearance), inn("marquee.scrollBars", .appearance),
            inn("marquee.tabOrder", .tabs), inn("marquee.tabs", .tabs),
            inn("marquee.server.id", .servers),
            inn(Phone.seerrAddress, .integrations, item: "Seerr", url: true), inn("marquee.seerr.", .integrations, item: "Seerr", prefix: true),
            inn(Phone.radarrAddress, .integrations, item: "Radarr", url: true),
            inn(Phone.sonarrAddress, .integrations, item: "Sonarr", url: true),
            inn(Phone.bazarrAddress, .integrations, item: "Bazarr", url: true),
            inn(Phone.homeLabberAddress, .integrations, item: "HomeLabber", url: true),
            inn("marquee.speechDock.", .integrations, item: "SpeechDock", prefix: true),
            inn("marquee.diag.", .integrations, item: "Diagnostic Logs", prefix: true),
            inn("marquee.cast.", .integrations, item: "Chromecast", prefix: true),
            inn("marquee.remote.", .remote, prefix: true),
            inn("marquee.glasses.", .bigScreen, prefix: true),
            inn("marquee.downloads.settings", .downloads),
            inn("marquee.live.", .live, prefix: true),
            inn("marquee.tracks.", .tracks, prefix: true),
            inn("marquee.", .other, prefix: true),

            Rule(store: Phone.remote, key: "", isPrefix: true, classification: .init(group: .remote, item: nil)),
            Rule(store: Phone.tv, key: "", isPrefix: true, classification: .init(group: .tvs, item: nil)),
            secret(Phone.seerrKey, "Seerr"), secret(Phone.radarrKey, "Radarr"), secret(Phone.sonarrKey, "Sonarr"),
            secret(Phone.bazarrKey, "Bazarr"), secret(Phone.homeLabberToken, "HomeLabber"), secret(Phone.diagToken, "Diagnostic Logs"),
        ])
    }()
}

/// How the phone's own entries and the integrations either platform can apply turn into each other.
extension BackupScope {
    private static let links: [(name: String, address: String?, secret: String?, options: [String: String])] = [
        (BackupIntegrationName.seerr, Phone.seerrAddress, Phone.seerrKey, ["pulsarr": Phone.seerrPulsarr]),
        (BackupIntegrationName.radarr, Phone.radarrAddress, Phone.radarrKey, [:]),
        (BackupIntegrationName.sonarr, Phone.sonarrAddress, Phone.sonarrKey, [:]),
        (BackupIntegrationName.bazarr, Phone.bazarrAddress, Phone.bazarrKey, [:]),
        (BackupIntegrationName.speechDock, Phone.speechDockAddress, nil, [:]),
        (BackupIntegrationName.homeLabber, Phone.homeLabberAddress, Phone.homeLabberToken, [:]),
        (BackupIntegrationName.diagnostics, Phone.diagServer, Phone.diagToken, ["topic": Phone.diagTopic]),
    ]

    /// The integrations among a phone's `entries`: one for each that has an address.
    public static func integrations(fromPhone entries: [BackupEntry]) -> BackupIntegrations {
        func value(_ store: String, _ key: String?) -> BackupValue? {
            key.flatMap { key in entries.first { $0.store == store && $0.key == key }?.value }
        }
        func text(_ store: String, _ key: String?) -> String? {
            switch value(store, key) {
            case .string(let text)?: text.isEmpty ? nil : text
            case .bool(let flag)?: flag ? "true" : "false"
            default: nil
            }
        }
        var result: BackupIntegrations = [:]
        for link in links {
            guard let address = text(Phone.defaults, link.address) else { continue }
            var integration = BackupIntegration(address: address, secret: text(Phone.secret, link.secret))
            for (option, key) in link.options {
                if let found = text(Phone.defaults, key) { integration.options[option] = found }
            }
            result[link.name] = integration
        }
        return result
    }

    /// The phone's entries for `integrations`: an address and a secret for each integration that has one.
    public static func phoneEntries(from integrations: BackupIntegrations) -> [BackupEntry] {
        var entries: [BackupEntry] = []
        for link in links {
            guard let integration = integrations[link.name], let address = integration.address, !address.isEmpty,
                  let key = link.address else { continue }
            func add(_ store: String, _ key: String, _ value: BackupValue) {
                if let classification = phone.classify(store: store, key: key) {
                    entries.append(BackupEntry(store: store, key: key, group: classification.group, item: classification.item, value: value))
                }
            }
            add(Phone.defaults, key, .string(address))
            if let secretKey = link.secret, let secret = integration.secret, !secret.isEmpty {
                add(Phone.secret, secretKey, .string(secret))
            }
            for (option, optionKey) in link.options {
                guard let text = integration.options[option] else { continue }
                add(Phone.defaults, optionKey, option == "pulsarr" ? .bool(text == "true") : .string(text))
            }
        }
        return entries
    }
}
