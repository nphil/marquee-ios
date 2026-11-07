import MarqueeCore
import SwiftUI

/// One screen's server content (DESIGN §11): nothing until the first answer, then the last good answer,
/// kept through later failures together with when it arrived.
@MainActor @Observable
final class Remote<Value: Sendable> {
    private(set) var value: Value?
    private(set) var loadedAt: Date?
    private(set) var failure: PlexError?
    private(set) var isLoading = false
    /// Bumped by `retry()`; a view keys its loading task on it.
    private(set) var attempt = 0
    @ObservationIgnored private var generation = 0

    /// Loads afresh. A load that a newer one overtook, or whose task was cancelled, changes nothing.
    func load(_ fetch: @MainActor () async throws -> Value) async {
        generation &+= 1
        let current = generation
        isLoading = true
        let outcome: Result<Value, any Error>
        do {
            outcome = .success(try await fetch())
        } catch {
            outcome = .failure(error)
        }
        guard current == generation else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let fresh):
            value = fresh
            loadedAt = .now
            failure = nil
        case .failure(let error):
            failure = error as? PlexError ?? .unreachable(.other)
        }
    }

    func retry() {
        attempt += 1
    }

    /// Edits the content in place, e.g. to show a change before the server confirms it.
    func update(_ change: (inout Value) -> Void) {
        guard var current = value else { return }
        change(&current)
        value = current
    }
}

/// What a screen's loading task restarts on: another library (a new server or profile), Retry, and any
/// screen-specific input such as a query.
struct LoadKey<Extra: Hashable>: Hashable {
    let library: ObjectIdentifier?
    let attempt: Int
    var extra: Extra
}

extension LoadKey where Extra == Int {
    init(library: ObjectIdentifier?, attempt: Int) {
        self.init(library: library, attempt: attempt, extra: 0)
    }
}

/// The states around a screen's content: a static skeleton while the first answer is on its way, a failure
/// page when there is nothing to show, and once content exists, the content with a banner above it when a
/// later refresh failed.
struct RemoteContent<Value: Sendable, Content: View, Skeleton: View>: View {
    let remote: Remote<Value>
    @ViewBuilder let content: (Value) -> Content
    @ViewBuilder let skeleton: () -> Skeleton

    @Environment(\.plexLibrary) private var library
    @Environment(\.sessionActions) private var session

    var body: some View {
        if let value = remote.value {
            content(value)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let failure = remote.failure, let loadedAt = remote.loadedAt, failure != .unauthorized {
                        OfflineBanner(server: serverName, since: loadedAt, isRetrying: remote.isLoading) { remote.retry() }
                    }
                }
        } else if let failure = remote.failure, !remote.isLoading {
            FailureState(failure: failure, server: serverName, retry: { remote.retry() }, signIn: session.signInAgain)
        } else {
            skeleton()
                .overlay { LoadingNote { remote.retry() } }
                .accessibilityElement(children: .contain)
        }
    }

    private var serverName: String {
        library?.server.name ?? "the server"
    }
}

/// `RemoteContent` for a list that loads a page at a time. A list the server answered with no titles at
/// all shows `empty`. A screen that pins the offline banner itself turns `banner` off.
struct PagedContent<Item: Identifiable & Sendable, Content: View, Skeleton: View, Empty: View>: View {
    let loader: PagedLoader<Item>
    var banner = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let skeleton: () -> Skeleton
    @ViewBuilder let empty: () -> Empty

    @Environment(\.plexLibrary) private var library
    @Environment(\.sessionActions) private var session

    var body: some View {
        if !loader.items.isEmpty {
            content()
                .safeAreaInset(edge: .top, spacing: 0) {
                    if banner, let failure, let loadedAt = loader.loadedAt, failure != .unauthorized {
                        OfflineBanner(server: serverName, since: loadedAt, isRetrying: loader.isLoading, retry: refresh)
                    }
                }
        } else if let failure, !loader.isLoading {
            FailureState(failure: failure, server: serverName, retry: refresh, signIn: session.signInAgain)
        } else if loader.loadedAt != nil, !loader.isLoading {
            empty()
        } else {
            skeleton()
                .overlay { LoadingNote(retry: refresh) }
                .accessibilityElement(children: .contain)
        }
    }

    private var failure: PlexError? {
        loader.failure.map { $0 as? PlexError ?? .unreachable(.other) }
    }

    private var serverName: String {
        library?.server.name ?? "the server"
    }

    private func refresh() {
        Task { await loader.refresh() }
    }
}

/// Words over a skeleton (DESIGN §11): none for the first second, then "Loading", then after a real wait
/// "Still loading" with Retry.
private struct LoadingNote: View {
    let retry: @MainActor () -> Void
    @State private var stage = Stage.quiet
    @Environment(\.theme) private var theme

    private enum Stage {
        case quiet, loading, slow
    }

    var body: some View {
        VStack(spacing: Space.s3) {
            switch stage {
            case .quiet:
                EmptyView()
            case .loading:
                Text("Loading")
            case .slow:
                Text("Still loading")
                Button("Retry", action: retry)
                    .buttonStyle(.pill)
            }
        }
        .textRole(.label)
        .foregroundStyle(theme.ink2)
        .padding(Space.s5)
        .background {
            if stage != .quiet {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(theme.canvas)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            stage = .loading
            try? await Task.sleep(for: .seconds(14))
            guard !Task.isCancelled else { return }
            stage = .slow
        }
    }
}

/// Nothing to show and the last load failed (DESIGN §11).
struct FailureState: View {
    let failure: PlexError
    let server: String
    let retry: @MainActor () -> Void
    let signIn: @MainActor () -> Void

    var body: some View {
        switch failure {
        case .unauthorized:
            EmptyState(
                title: "Sign in again",
                message: "Plex no longer accepts this sign-in.",
                systemImage: "person.crop.circle.badge.exclamationmark",
                action: EmptyState.Action(title: "Sign In", systemImage: "person.crop.circle", perform: signIn)
            )
        case .unreachable:
            EmptyState(
                title: "Can't reach \(server)",
                message: "Check that it is on and this iPhone is online.",
                systemImage: "wifi.slash",
                action: EmptyState.Action(title: "Retry", systemImage: "arrow.clockwise", perform: retry)
            )
        default:
            EmptyState(
                title: "Something went wrong",
                message: "\(server) sent an answer Marquee did not expect.",
                systemImage: "exclamationmark.triangle",
                action: EmptyState.Action(title: "Retry", systemImage: "arrow.clockwise", perform: retry)
            )
        }
    }
}

/// The pinned row over content that could not be refreshed (DESIGN §11): a card with the age of what is
/// shown, and Retry.
struct OfflineBanner: View {
    let server: String
    let since: Date
    let isRetrying: Bool
    let retry: @MainActor () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(spacing: Space.s3) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(theme.ink2)
                .accessibilityHidden(true)
            TimelineView(.everyMinute) { context in
                Text("Can't reach \(server). Showing \(Self.age(of: since, at: context.date)).")
                    .textRole(.label)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: retry) {
                Text("Retry")
                    .textRole(.headline)
                    .foregroundStyle(theme.accentText)
                    .frame(minWidth: Size.target, minHeight: Size.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
        }
        .padding(.leading, Space.s4)
        .padding(.trailing, Space.s2)
        .padding(.vertical, Space.s1)
        .background(theme.glass, in: shape)
        .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
        .shadow(color: theme.mode == .light ? theme.ink.opacity(0.08) : .clear, radius: 2, y: 2)
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.s2)
    }

    /// "just now", "12 min ago", "3 h ago".
    static func age(of date: Date, at now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "what loaded just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }
}

/// Static fills in the shape of what is loading (DESIGN §11), swapped for content at once when it lands.
enum Skeleton {
    /// A shelf header bar over a row of poster fills.
    struct Shelf: View {
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: Space.s3) {
                Capsule().fill(theme.trackOff).frame(width: 160, height: 20)
                    .padding(.horizontal, Space.inset)
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                            .fill(theme.trackOff)
                            .frame(width: Size.gridMin, height: Size.gridMin * 1.5)
                    }
                }
                .padding(.leading, Space.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            .accessibilityHidden(true)
        }
    }

    /// A page of poster fills in grid columns.
    struct Grid: View {
        let metrics: PosterGridMetrics
        @Environment(\.theme) private var theme

        var body: some View {
            LazyVGrid(columns: metrics.gridItems, spacing: Space.s4) {
                ForEach(0..<(metrics.columns * 4), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: metrics.cellWidth, height: (metrics.cellWidth * 1.5).rounded())
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Rows with a small art fill and two text bars.
    struct Rows: View {
        var artSize = CGSize(width: 56, height: 84)
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(spacing: Space.s3) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: Space.s3) {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(theme.trackOff)
                            .frame(width: artSize.width, height: artSize.height)
                        VStack(alignment: .leading, spacing: Space.s2) {
                            Capsule().fill(theme.trackOff).frame(width: 160, height: 14)
                            Capsule().fill(theme.trackOff).frame(width: 96, height: 12)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, Space.inset)
            .accessibilityHidden(true)
        }
    }
}
