import Foundation

/// Which way the phone remote moves the glasses' focus.
public enum FocusMove: Sendable, Equatable, CaseIterable {
    case up, down, left, right

    public var isHorizontal: Bool { self == .left || self == .right }
}

/// Where the focus sits on a glasses page: rows of items, each row as long as its count.
///
/// On a shelves page every row keeps its own place, as TV home screens do; on a grid the column carries
/// from row to row, held where a shorter row clamped it. Empty rows are passed over. A move past the
/// last item reports `edge`, which the remote plays as the edge cue.
public struct FocusGrid: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case shelves, grid }
    public enum Outcome: Sendable, Equatable { case moved, edge }

    public let style: Style
    public private(set) var rows: [Int]
    public private(set) var row = 0
    public private(set) var column = 0
    /// The column each row was left at (shelves).
    private var kept: [Int]
    /// The column a grid returns to once a shorter row has clamped it.
    private var wanted = 0

    public init(rows: [Int] = [], style: Style = .shelves) {
        self.style = style
        self.rows = rows
        kept = Array(repeating: 0, count: rows.count)
        row = rows.firstIndex { $0 > 0 } ?? 0
    }

    /// Lays a flat list into rows of `columns`.
    public static func gridRows(count: Int, columns: Int) -> [Int] {
        guard count > 0, columns > 0 else { return [] }
        let full = count / columns
        let rest = count % columns
        return Array(repeating: columns, count: full) + (rest > 0 ? [rest] : [])
    }

    public var isEmpty: Bool { !rows.contains { $0 > 0 } }

    /// The focused item's position in a flat list laid out by `gridRows`.
    public var flatIndex: Int { rows.prefix(row).reduce(0, +) + column }

    /// The column a row shows: the focus in the focused row; on shelves, where each other row was left.
    public func column(inRow index: Int) -> Int {
        if index == row { return column }
        guard style == .shelves, kept.indices.contains(index) else { return 0 }
        return kept[index]
    }

    public mutating func move(_ direction: FocusMove) -> Outcome {
        guard !isEmpty else { return .edge }
        switch direction {
        case .left, .right:
            let next = column + (direction == .right ? 1 : -1)
            guard rows.indices.contains(row), (0..<rows[row]).contains(next) else { return .edge }
            column = next
            remember()
            return .moved
        case .up, .down:
            let step = direction == .down ? 1 : -1
            var target = row + step
            while rows.indices.contains(target), rows[target] == 0 { target += step }
            guard rows.indices.contains(target) else { return .edge }
            row = target
            column = min(style == .shelves ? kept[target] : wanted, rows[target] - 1)
            return .moved
        }
    }

    /// Puts the focus on one item, as when a page reopens where it was left.
    public mutating func focus(row: Int, column: Int) {
        guard rows.indices.contains(row), rows[row] > 0 else { return }
        self.row = row
        self.column = min(max(column, 0), rows[row] - 1)
        remember()
    }

    /// New counts as a page's content loads or changes; the focus stays put where it still fits.
    public mutating func update(rows: [Int]) {
        guard rows != self.rows else { return }
        kept = rows.indices.map { $0 < kept.count ? kept[$0] : 0 }
        self.rows = rows
        guard !isEmpty else {
            row = 0
            column = 0
            return
        }
        if !rows.indices.contains(row) || rows[row] == 0 {
            let earlier = rows.indices.prefix(min(row, rows.count)).last { rows[$0] > 0 }
            row = earlier ?? rows.firstIndex { $0 > 0 } ?? 0
        }
        column = min(column, rows[row] - 1)
    }

    private mutating func remember() {
        wanted = column
        if kept.indices.contains(row) { kept[row] = column }
    }
}
