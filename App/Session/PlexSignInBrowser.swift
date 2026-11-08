import AuthenticationServices
import UIKit

/// The plex.tv sign-in page in a browser sheet, as Plezy and plex.tv's own guide do it: no forward
/// URL, the app polls the code and closes the sheet itself once it is approved.
@MainActor
final class PlexSignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ url: URL) {
        session?.cancel()
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("marquee")) { _, _ in }
        session.presentationContextProvider = self
        // A private session, so plex.tv always asks which account signs in. With Safari's cookies it
        // opened on whichever account Safari had, and signing out there left plex.tv's auth page for
        // its web app, so the code was never approved (2026-11-08).
        session.prefersEphemeralWebBrowserSession = true
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
