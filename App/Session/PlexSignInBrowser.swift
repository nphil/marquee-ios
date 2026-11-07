import AuthenticationServices
import UIKit

/// The plex.tv approval page in a browser sheet. Sign-in never waits on the sheet: the app polls the
/// code and closes the sheet itself once it is approved, because plex.tv does not always forward back
/// (2026-11-07: an account already signed in to plex.tv was left on plex.tv's page, with no way on).
@MainActor
final class PlexSignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ url: URL) {
        session?.cancel()
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("marquee")) { _, _ in }
        session.presentationContextProvider = self
        // Shares Safari's cookies, so an account already signed in to plex.tv only has to approve.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        _ = session.start()
    }

    func close() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
