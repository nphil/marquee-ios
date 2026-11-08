import MarqueeCore
import SwiftUI

/// The account's servers (DESIGN §8.0): one 56 pt row each with the name, the owner and how the phone
/// reaches it. Choosing one is remembered. Shown after sign-in, and from Settings to change server.
struct ServerListView: View {
    /// After sign-in the list is the whole screen and offers Sign out; from Settings it pops back.
    var isRoot = false

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    var body: some View {
        Group {
            if session.servers.isEmpty {
                EmptyState(
                    title: "No servers found",
                    message: "Servers on this Plex account, its Home and those shared with it show here.",
                    systemImage: "server.rack",
                    action: .init(title: "Retry", systemImage: "arrow.clockwise") {
                        Task { await session.reloadServers() }
                    }
                )
            } else {
                List(session.servers) { server in
                    Button {
                        Haptics.selection()
                        session.choose(server)
                        if !isRoot { dismiss() }
                    } label: {
                        ServerRow(server: server, isCurrent: !isRoot && session.server?.id == server.id)
                    }
                    .listRowBackground(theme.sheet)
                    .accessibilityIdentifier("server.\(server.id)")
                }
                .themedList(theme)
                .refreshable { await session.reloadServers() }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out") { confirmingSignOut = true }
                        .accessibilityIdentifier("servers.signOut")
                        .signOutConfirmation(isPresented: $confirmingSignOut, session: session)
                }
            }
        }
    }
}

private struct ServerRow: View {
    let server: PlexServer
    let isCurrent: Bool

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var reach: Reach = .checking
    /// The address the app uses, for the current server.
    @State private var address: String?
    /// The latest probe round's lines, for the current server.
    @State private var probeLines: [String] = []

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(spacing: Space.s3))
        layout {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(server.name)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                Text(owner)
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                if let address {
                    Text("In use: \(address)")
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                        .accessibilityIdentifier("server.\(server.id).address")
                }
                ForEach(probeLines, id: \.self) { line in
                    Text(line)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReachLabel(reach: reach)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.accentText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Size.rowMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        // Checks again when the phone changes networks. The current server reports the address the
        // app actually uses and how its last probe went, rather than a fresh probe of its own.
        .task(id: session.networkChanges) {
            reach = .checking
            do {
                let probing = isCurrent ? session.library?.connection ?? session.probe(server) : session.probe(server)
                let connection = try await probing.connection()
                reach = Reach(connection)
                if isCurrent {
                    address = "\(connection.kindWord) \(connection.displayAddress)"
                    probeLines = await probing.probeRounds.last?.lines ?? []
                }
            } catch is CancellationError {
            } catch {
                reach = .offline
            }
        }
    }

    private var owner: String {
        if server.isOwned { return "Yours" }
        if server.isHome { return server.ownerName.map { "Plex Home · \($0)" } ?? "Plex Home" }
        return server.ownerName.map { "Shared by \($0)" } ?? "Shared with you"
    }
}

/// How the phone reaches a server: a glyph in the tone of the answer and a word, so the meaning
/// never rests on colour.
private enum Reach: Equatable {
    case checking, local, remote, relay, offline

    init(_ connection: PlexConnection) {
        self = connection.isRelay ? .relay : connection.isLocal ? .local : .remote
    }

    var word: String {
        switch self {
        case .checking: "Checking"
        case .local: "Local"
        case .remote: "Remote"
        case .relay: "Relay"
        case .offline: "Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "circle.dotted"
        case .local: "wifi"
        case .remote: "globe"
        case .relay: "arrow.triangle.branch"
        case .offline: "wifi.slash"
        }
    }
}

private struct ReachLabel: View {
    let reach: Reach
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: reach.systemImage)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            Text(reach.word)
                .textRole(.label)
                .foregroundStyle(theme.ink2)
        }
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.12), value: reach)
    }

    /// DESIGN §5.2: positive is fine, info ordinary, warning slow, danger down.
    private var tone: Color {
        switch reach {
        case .checking: theme.ink2
        case .local: theme.positive
        case .remote: theme.info
        case .relay: theme.warning
        case .offline: theme.danger
        }
    }
}
