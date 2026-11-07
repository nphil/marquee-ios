import MarqueeCore
import SwiftUI

/// Home's profile button (DESIGN §8.1): the profile's photo, opening Settings, whose Account row switches
/// profiles, as in the Apple TV app.
struct ProfileButton: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Button {
            session.showsSettings = true
        } label: {
            AvatarView(user: session.user, size: Size.target - Space.s4)
        }
        .accessibilityLabel("Settings")
        .accessibilityValue(session.user?.title ?? "")
        .accessibilityIdentifier("profile.button")
    }
}

/// The Plex Home's profiles in a sheet (DESIGN §7). A protected profile asks for its PIN on a page
/// pushed inside the sheet; the sheet closes once the switch is done.
struct ProfileSwitcher: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var path: [PlexHomeUser] = []
    @State private var detent = PresentationDetent.medium
    @State private var switching: PlexHomeUser?
    @State private var failed: PlexHomeUser?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(profiles) { profile in
                        Button {
                            pick(profile)
                        } label: {
                            ProfileRow(profile: profile, isCurrent: profile.uuid == session.user?.uuid, isSwitching: profile == switching)
                        }
                        .disabled(switching != nil)
                        .accessibilityIdentifier("profile.\(profile.uuid)")
                    }
                }
                .listRowBackground(theme.sheet)

                if let failed {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(theme.danger)
                                .accessibilityHidden(true)
                            Text("Couldn't switch to \(failed.title). Check the connection and try again.")
                                .foregroundStyle(theme.ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("profile.failed")
                    }
                    .listRowBackground(theme.sheet)
                }
            }
            // A partial sheet keeps the system glass; at full height iOS makes the sheet opaque and the
            // list takes the canvas (DESIGN §6). A landscape phone always shows the sheet at full height.
            .themedList(theme, onCanvas: detent == .large || verticalSizeClass == .compact)
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("profile.close")
                }
            }
            .navigationDestination(for: PlexHomeUser.self) { profile in
                PINPadView(profile: profile) { dismiss() }
            }
        }
        // The keypad needs the full height, so the PIN page allows only that.
        .presentationDetents(path.isEmpty ? [.medium, .large] : [.large], selection: $detent)
    }

    /// An account outside a Plex Home has no list; it shows itself.
    private var profiles: [PlexHomeUser] {
        if !session.homeUsers.isEmpty { return session.homeUsers }
        return session.user.map { [$0] } ?? []
    }

    private func pick(_ profile: PlexHomeUser) {
        guard profile.uuid != session.user?.uuid else {
            dismiss()
            return
        }
        failed = nil
        if profile.isProtected {
            detent = .large
            path.append(profile)
            return
        }
        switching = profile
        Task {
            do {
                try await session.switchUser(profile, pin: nil)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                failed = profile
            }
            switching = nil
        }
    }
}

private struct ProfileRow: View {
    let profile: PlexHomeUser
    let isCurrent: Bool
    let isSwitching: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s3) {
            AvatarView(user: profile, size: Size.target - Space.s2)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(profile.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                if profile.isRestricted {
                    Text("Restricted")
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSwitching {
                ProgressView()
            } else if isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.accentText)
                    .accessibilityHidden(true)
            } else if profile.isProtected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(theme.ink2)
                    .accessibilityLabel("Needs a PIN")
            }
        }
        .frame(minHeight: Size.rowMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
