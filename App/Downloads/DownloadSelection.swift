import MarqueeCore
import SwiftUI

/// What a row needs while a Downloads page is choosing downloads to remove: which are ticked, and a way
/// to tick them.
struct DownloadSelection {
    enum Tick {
        case none, some, all
    }

    let picked: Set<String>
    /// Ticks the downloads, or clears them when every one of them is ticked already.
    let toggle: @MainActor ([String]) -> Void

    func tick(_ ids: [String]) -> Tick {
        let count = ids.filter(picked.contains).count
        return count == 0 ? .none : count == ids.count ? .all : .some
    }
}

extension EnvironmentValues {
    /// Set while a page is in Select mode by `selectingDownloads`; nil otherwise.
    @Entry var downloadSelection: DownloadSelection? = nil
}

/// The circle at the start of a row in Select mode: empty, part ticked (a show with some of its episodes
/// picked) or ticked.
struct DownloadTick: View {
    let tick: DownloadSelection.Tick
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tick == .none ? theme.ink3 : theme.accent)
            .frame(width: Space.s7, height: Size.target)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch tick {
        case .none: "circle"
        case .some: "minus.circle.fill"
        case .all: "checkmark.circle.fill"
        }
    }
}

extension View {
    /// Adds Select to the navigation bar. In Select mode the rows below take ticks (`downloadSelection`)
    /// and the bottom bar is Select All and Remove; otherwise it shows `idle`.
    func selectingDownloads<Idle: View>(_ records: [DownloadRecord], @ViewBuilder idle: () -> Idle) -> some View {
        modifier(SelectingDownloads(records: records, idle: idle()))
    }

    func selectingDownloads(_ records: [DownloadRecord]) -> some View {
        selectingDownloads(records) { EmptyView() }
    }
}

private struct SelectingDownloads<Idle: View>: ViewModifier {
    /// Every download the page lists.
    let records: [DownloadRecord]
    let idle: Idle

    @Environment(\.confirmDownloadRemoval) private var confirmRemoval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var selecting = false
    @State private var picked: Set<String> = []

    private var ids: [String] { records.map(\.id) }

    func body(content: Content) -> some View {
        content
            .environment(\.downloadSelection, selecting ? DownloadSelection(picked: picked, toggle: toggle) : nil)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if selecting {
                    actions
                } else {
                    idle
                }
            }
            .toolbar {
                if !records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selecting ? "Done" : "Select") { setSelecting(!selecting) }
                            .accessibilityIdentifier("downloads.select")
                    }
                }
            }
            .onChange(of: ids) { _, ids in prune(to: ids) }
    }

    private var actions: some View {
        let chosen = records.filter { picked.contains($0.id) }
        let everything = !records.isEmpty && chosen.count == records.count
        return HStack(spacing: Space.s3) {
            Button {
                withAnimation(Motion.label) { picked = everything ? [] : Set(ids) }
            } label: {
                Text(everything ? "Deselect All" : "Select All")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tonal)
            .accessibilityIdentifier("downloads.selectAll")
            Button(role: .destructive) {
                confirmRemoval(chosen)
            } label: {
                Label {
                    Text(chosen.isEmpty ? "Remove" : "Remove (\(chosen.count))")
                } icon: {
                    Image(systemName: "trash").foregroundStyle(theme.danger)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tonal)
            .disabled(chosen.isEmpty)
            .accessibilityLabel(removeLabel(count: chosen.count))
            .accessibilityIdentifier("downloads.removeSelected")
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.s2)
    }

    private func removeLabel(count: Int) -> String {
        switch count {
        case 0: "Remove"
        case 1: "Remove 1 download"
        default: "Remove \(count) downloads"
        }
    }

    private func toggle(_ ids: [String]) {
        if ids.allSatisfy(picked.contains) {
            picked.subtract(ids)
        } else {
            picked.formUnion(ids)
        }
    }

    private func setSelecting(_ value: Bool) {
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            selecting = value
            picked = []
        }
    }

    /// Downloads that went away (removed here, finished watching, or by another page) leave the ticks;
    /// emptying them by removal ends Select mode, as does an empty page.
    private func prune(to ids: [String]) {
        guard selecting else { return }
        if ids.isEmpty {
            setSelecting(false)
            return
        }
        guard !picked.isEmpty else { return }
        picked.formIntersection(ids)
        if picked.isEmpty { setSelecting(false) }
    }
}
