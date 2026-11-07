import Foundation

/// A server-side play queue. For episodes it holds the rest of the show, so Up Next needs no other call.
public struct PlexPlayQueue: Sendable, Hashable, Identifiable {
    public var id: Int
    public var selectedItemID: Int?
    /// Index of the selected item in the whole queue.
    public var selectedItemOffset: Int?
    public var totalCount: Int
    public var version: Int?
    /// The window of the queue around the selected item.
    public var items: [PlexMetadata]

    public init(id: Int, selectedItemID: Int?, selectedItemOffset: Int?, totalCount: Int, version: Int?, items: [PlexMetadata]) {
        self.id = id
        self.selectedItemID = selectedItemID
        self.selectedItemOffset = selectedItemOffset
        self.totalCount = totalCount
        self.version = version
        self.items = items
    }

    init?(_ container: PlexMediaContainer) {
        guard let id = container.playQueueID else { return nil }
        self.init(
            id: id,
            selectedItemID: container.playQueueSelectedItemID,
            selectedItemOffset: container.playQueueSelectedItemOffset,
            totalCount: container.playQueueTotalCount ?? container.metadata.count,
            version: container.playQueueVersion,
            items: container.metadata
        )
    }

    public var selectedItem: PlexMetadata? {
        items.first { $0.playQueueItemID != nil && $0.playQueueItemID == selectedItemID }
    }

    /// The item after `item` in the queue, if the window holds it.
    public func item(after item: PlexMetadata) -> PlexMetadata? {
        guard let index = position(of: item), index + 1 < items.count else { return nil }
        return items[index + 1]
    }

    /// The item before `item` in the queue, if the window holds it.
    public func item(before item: PlexMetadata) -> PlexMetadata? {
        guard let index = position(of: item), index > 0 else { return nil }
        return items[index - 1]
    }

    private func position(of item: PlexMetadata) -> Int? {
        if let queueID = item.playQueueItemID, let index = items.firstIndex(where: { $0.playQueueItemID == queueID }) {
            return index
        }
        return items.firstIndex { $0.ratingKey == item.ratingKey }
    }
}
