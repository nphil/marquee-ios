import MarqueeCore
import SwiftUI

/// The iPhone's storage in one bar, as in Netflix's Downloads: what Marquee's downloads take, what
/// everything else takes, and what is free, with the figures under it. Measured when the list changes and
/// every few seconds while a download is on its way. Draws nothing until the system has said how large the
/// storage is.
struct DownloadStorageBar: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var usage: StorageUsage?

    /// When to measure again; the bytes themselves change too often to be a key.
    private struct Refresh: Equatable {
        let count: Int
        let finished: Int
        let active: Bool
        let foreground: Bool
    }

    var body: some View {
        let records = session.downloads.records
        let key = Refresh(
            count: records.count,
            finished: records.count { $0.phase == .done },
            active: records.contains { $0.phase.isActive },
            foreground: scenePhase == .active
        )
        VStack(spacing: 0) {
            if let usage, usage.isKnown {
                VStack(alignment: .leading, spacing: Space.s2) {
                    bar(usage)
                    legend(usage)
                }
                .padding(.horizontal, Space.inset)
                .padding(.vertical, Space.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Storage")
                .accessibilityValue(spoken(usage))
                .accessibilityIdentifier("downloads.storage")
            }
        }
        .task(id: key) {
            guard key.foreground else { return }
            let store = session.downloads.store
            repeat {
                usage = await StorageMeasure.read(store)
                guard key.active else { return }
                try? await Task.sleep(for: .seconds(5))
            } while !Task.isCancelled
        }
    }

    private func bar(_ usage: StorageUsage) -> some View {
        let marquee = usage.downloadsShare
        let used = min(1, marquee + usage.otherShare)
        return theme.trackOff
            .overlay(alignment: .leading) {
                theme.ink3.scaleEffect(x: used, y: 1, anchor: .leading)
            }
            .overlay(alignment: .leading) {
                // A few megabytes would vanish at one pixel; the sliver says they are there.
                theme.accent.scaleEffect(x: marquee > 0 ? max(marquee, 0.01) : 0, y: 1, anchor: .leading)
            }
            .frame(height: Space.s2)
            .clipShape(Capsule())
    }

    private func legend(_ usage: StorageUsage) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s4) { entries(usage) }
            VStack(alignment: .leading, spacing: Space.s1) { entries(usage) }
        }
        .textRole(.caption)
    }

    @ViewBuilder
    private func entries(_ usage: StorageUsage) -> some View {
        entry("Marquee", usage.downloads, theme.accent)
        entry("Other", usage.other, theme.ink3)
        entry("Free", usage.free, theme.trackOff)
    }

    private func entry(_ title: String, _ bytes: Int64, _ swatch: Color) -> some View {
        HStack(spacing: Space.s1) {
            Circle()
                .fill(swatch)
                .frame(width: Space.s2, height: Space.s2)
            Text(title)
                .foregroundStyle(theme.ink2)
            Text(DownloadText.size(bytes))
                .foregroundStyle(theme.ink)
                .monospacedDigit()
        }
    }

    private func spoken(_ usage: StorageUsage?) -> String {
        guard let usage, usage.isKnown else { return "" }
        return "Marquee \(DownloadText.size(usage.downloads)), other \(DownloadText.size(usage.other)), \(DownloadText.size(usage.free)) free"
    }
}

private enum StorageMeasure {
    /// The volume's size and free space, with what every download takes on disk, off the main thread:
    /// the downloads are measured file by file. Free space is what the system would free up for something
    /// the user asked for, as iPhone Storage counts it.
    @concurrent
    static func read(_ store: DownloadStore) async -> StorageUsage {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)
        return StorageUsage(
            total: Int64(values?.volumeTotalCapacity ?? 0),
            free: values?.volumeAvailableCapacityForImportantUsage ?? 0,
            downloads: store.bytesOnDisk()
        )
    }
}
