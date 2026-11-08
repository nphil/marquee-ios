import Foundation

/// The hosts the app's transport security lets through without TLS: private, link-local and tailnet
/// addresses, `.local` names and single-label names. Integrations allow plain http only to these.
enum HomeNetwork {
    static func contains(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        if !host.contains(".") || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        // Carrier-grade NAT, which Tailscale uses for its addresses.
        case (100, 64...127): return true
        default: return false
        }
    }
}
