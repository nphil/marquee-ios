import Network

/// Brings up iOS's Local Network prompt at launch, so it is answered before the server list or the first
/// play probes a LAN address: while the prompt is up, every LAN connection fails and a remote address
/// wins. Browsing for Plex's Bonjour service is what makes iOS ask, once per install; the browse stops
/// after a few seconds, as nothing uses its results.
@MainActor
final class LocalNetworkAccess {
    private var browser: NWBrowser?

    func request() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_plex._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        self.browser = browser
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            browser.cancel()
            self?.browser = nil
        }
    }
}
