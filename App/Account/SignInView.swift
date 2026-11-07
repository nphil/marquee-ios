import AuthenticationServices
import MarqueeCore
import SwiftUI

/// Sign-in (DESIGN §8.0): the Marquee mark and one Sign in button. The plex.tv/link code is the
/// fallback for a phone whose browser cannot finish the sign-in. Waiting, an expired code and a
/// refused or unreachable sign-in (§11) take the button's place on the same screen.
struct SignInView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.webAuthenticationSession) private var browser
    @State private var confirmingSignOut = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Space.s7) {
                    MarqueeMark()
                        .frame(maxWidth: 240)
                        .accessibilityHidden(true)
                    Text("Marquee")
                        .textRole(.display)
                        .foregroundStyle(theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    content
                        .frame(maxWidth: 420)
                }
                .padding(.horizontal, Space.inset)
                .padding(.vertical, Space.s7)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(theme.canvas)
        .signOutConfirmation(isPresented: $confirmingSignOut, session: session)
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .signingIn:
            if let code = session.linkCode {
                codePanel(code)
            } else {
                waiting
            }
        case .failed(let error):
            failure(error)
        default:
            signInButtons
        }
    }

    private var signInButtons: some View {
        VStack(spacing: Space.s4) {
            Button {
                session.signIn(with: browser)
            } label: {
                Text("Sign in").frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
            .accessibilityIdentifier("signin.plex")
            Button("Use a code instead") {
                session.signInWithCode()
            }
            .textRole(.body)
            .foregroundStyle(theme.accentText)
            .frame(minHeight: Size.target)
            .accessibilityIdentifier("signin.code")
        }
    }

    private var waiting: some View {
        VStack(spacing: Space.s4) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.ink2)
            Text("Signing in")
                .textRole(.body)
                .foregroundStyle(theme.ink2)
            cancelButton
        }
    }

    private func codePanel(_ code: String) -> some View {
        VStack(spacing: Space.s4) {
            // Without fixedSize the stack holds this to one line and truncates it at larger text sizes.
            Text("On any device, go to plex.tv/link and enter")
                .textRole(.body)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(code)
                .textRole(.display)
                .tracking(6)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("signin.linkCode")
            HStack(spacing: Space.s2) {
                ProgressView()
                    .tint(theme.ink2)
                Text("Waiting for the code")
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            cancelButton
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity)
        .background(theme.glass, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(theme.edge, lineWidth: 1))
    }

    private var cancelButton: some View {
        Button("Cancel") {
            session.cancelSignIn()
        }
        .textRole(.body)
        .foregroundStyle(theme.accentText)
        .frame(minHeight: Size.target)
        .accessibilityIdentifier("signin.cancel")
    }

    @ViewBuilder
    private func failure(_ error: PlexError) -> some View {
        VStack(spacing: Space.s4) {
            Label(Self.message(for: error), systemImage: error == .unauthorized ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                .textRole(.body)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            switch error {
            case .pinExpired:
                Button {
                    session.signInWithCode()
                } label: {
                    Text("Get a new code").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill)
            case .unauthorized:
                Button {
                    session.signIn(with: browser)
                } label: {
                    Text("Sign in again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill)
            default:
                Button {
                    if session.canRetry {
                        session.retry()
                    } else {
                        session.signIn(with: browser)
                    }
                } label: {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill)
            }
            if session.canRetry {
                Button("Sign Out") {
                    confirmingSignOut = true
                }
                .textRole(.body)
                .foregroundStyle(theme.accentText)
                .frame(minHeight: Size.target)
            } else if error != .pinExpired {
                Button("Use a code instead") {
                    session.signInWithCode()
                }
                .textRole(.body)
                .foregroundStyle(theme.accentText)
                .frame(minHeight: Size.target)
            }
        }
        .accessibilityIdentifier("signin.failed")
    }

    private static func message(for error: PlexError) -> String {
        switch error {
        case .pinExpired: "The code expired."
        case .unauthorized: "Plex signed this phone out."
        case .unreachable: "Plex can't be reached. Check the connection."
        default: "Sign-in didn't finish."
        }
    }
}
