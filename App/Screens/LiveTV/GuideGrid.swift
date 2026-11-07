import MarqueeCore
import SwiftUI
import UIKit

/// The guide as a grid (docs/LIVE-TV.md §6.5): channels down the side, time across, each airing as wide
/// as it runs. A collection view with its own layout, because SwiftUI's lazy grids place cells in fixed
/// columns rather than by time. The channel column and the time ruler stay put while the airings scroll
/// under them, and the now line moves without a relayout.
struct GuideGrid: UIViewRepresentable {
    let channels: [LiveChannel]
    let guide: LiveGuide
    let now: Date
    let recordings: LiveRecordings
    let canRecord: Bool
    let favourites: [String]
    let theme: Theme
    /// Bumped to scroll back to now.
    let anchor: Int
    let actions: GuideActions
    @Binding var nowVisible: Bool

    func makeUIView(context: Context) -> GuideGridView {
        GuideGridView()
    }

    func updateUIView(_ view: GuideGridView, context: Context) {
        let environment = context.environment
        let binding = $nowVisible
        view.actions = actions
        view.onNowVisibility = { visible in
            if binding.wrappedValue != visible { binding.wrappedValue = visible }
        }
        view.update(
            GuideGridView.Content(
                channels: channels,
                guide: guide,
                now: now,
                recordings: recordings,
                canRecord: canRecord,
                favourites: Set(favourites)
            ),
            style: GuideGridView.Style(
                theme: theme,
                regular: environment.horizontalSizeClass == .regular,
                typeSize: environment.dynamicTypeSize,
                reduceMotion: environment.accessibilityReduceMotion
            ),
            anchor: anchor
        )
    }
}

/// What a guide row or cell asks of the screen.
struct GuideActions {
    var play: @MainActor (LiveChannel) -> Void = { _ in }
    var open: @MainActor (LiveAiring, LiveChannel) -> Void = { _, _ in }
    var record: @MainActor (LiveAiring, LiveChannel) -> Void = { _, _ in }
    var toggleFavourite: @MainActor (LiveChannel) -> Void = { _ in }
}

// MARK: - View

@MainActor
final class GuideGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    struct Content: Equatable {
        var channels: [LiveChannel]
        var guide: LiveGuide
        var now: Date
        var recordings: LiveRecordings
        var canRecord: Bool
        var favourites: Set<String>
    }

    struct Style: Equatable {
        var theme: Theme
        var regular: Bool
        var typeSize: DynamicTypeSize
        var reduceMotion: Bool
    }

    /// One cell of a row: an airing, or the whole span of a channel with no guide data.
    enum Item {
        case airing(LiveAiring)
        case gap
    }

    var actions = GuideActions()
    var onNowVisibility: ((Bool) -> Void)?

    private let layout = GuideLayout()
    private let collectionView: UICollectionView
    private let nowLine = UIView()
    private let nowPill = NowPill()
    private var content = Content(channels: [], guide: .empty, now: .distantPast, recordings: LiveRecordings(), canRecord: false, favourites: [])
    private var style: Style?
    private var rows: [[Item]] = []
    private var anchor: Int?
    private var needsAnchor = true
    private var reportedNowVisible: Bool?
    private var cornerDay = ""

    init() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.register(AiringCell.self, forCellWithReuseIdentifier: AiringCell.reuse)
        collectionView.register(ChannelHeader.self, forSupplementaryViewOfKind: GuideLayout.channelKind, withReuseIdentifier: ChannelHeader.reuse)
        collectionView.register(RulerSlot.self, forSupplementaryViewOfKind: GuideLayout.rulerKind, withReuseIdentifier: RulerSlot.reuse)
        collectionView.register(GuideCorner.self, forSupplementaryViewOfKind: GuideLayout.cornerKind, withReuseIdentifier: GuideCorner.reuse)
        collectionView.accessibilityIdentifier = "livetv.grid"
        collectionView.frame = bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(collectionView)

        // Above the airings, under the pinned column and ruler (zIndex 20).
        nowLine.isUserInteractionEnabled = false
        nowLine.layer.zPosition = 10
        nowLine.isHidden = true
        collectionView.addSubview(nowLine)
        nowPill.layer.zPosition = 25
        nowPill.isHidden = true
        collectionView.addSubview(nowPill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Updates

    func update(_ content: Content, style: Style, anchor: Int) {
        let old = self.content
        let oldStyle = self.style
        self.content = content
        self.style = style
        let metrics = GuideLayout.Metrics(regular: style.regular, typeSize: style.typeSize)
        let dataChanged = content.channels != old.channels || content.guide != old.guide
        if dataChanged {
            rows = content.channels.map { channel in
                let airings = content.guide.airings[channel.id] ?? []
                return airings.isEmpty ? [.gap] : airings.map(Item.airing)
            }
        }
        if dataChanged || metrics != layout.metrics {
            let origin = Self.origin(content.guide.from, now: content.now)
            let end = max(content.guide.to, origin.addingTimeInterval(30 * 60))
            let minutes = end.timeIntervalSince(origin) / 60
            let spans = zip(rows, content.channels).map { items, _ in
                items.map { item -> (Double, Double) in
                    switch item {
                    case .airing(let airing):
                        (airing.start.timeIntervalSince(origin) / 60, airing.end.timeIntervalSince(origin) / 60)
                    case .gap:
                        (0, minutes)
                    }
                }
            }
            layout.configure(metrics: metrics, origin: origin, minutes: minutes, spans: spans)
            collectionView.reloadData()
        } else if content != old || style != oldStyle {
            refreshVisible()
        }
        if style.theme != oldStyle?.theme {
            nowLine.backgroundColor = style.theme.roles.live.uiColor
            nowPill.apply(style.theme)
            if !dataChanged { refreshVisible() }
        }
        nowPill.text = LiveText.time(content.now)
        placeNow(animated: content.now != old.now && !style.reduceMotion && !dataChanged)
        if self.anchor != anchor {
            let first = self.anchor == nil
            self.anchor = anchor
            if first { needsAnchor = true } else { scrollToNow(animated: !style.reduceMotion) }
        }
        setNeedsLayout()
    }

    /// The grid starts on the half hour at or before the guide's first minute.
    private static func origin(_ from: Date, now: Date) -> Date {
        let start = from == .distantPast ? now.addingTimeInterval(-GuideCache.history) : from
        let seconds = start.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 1800).rounded(.down) * 1800)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = safeAreaInsets
        if collectionView.contentInset.bottom != insets.bottom {
            collectionView.contentInset.bottom = insets.bottom
            collectionView.verticalScrollIndicatorInsets.bottom = insets.bottom
        }
        layout.setInsets(leading: insets.left, trailing: insets.right)
        if needsAnchor, bounds.width > 0, !rows.isEmpty {
            needsAnchor = false
            collectionView.layoutIfNeeded()
            scrollToNow(animated: false)
        }
        placeNow(animated: false)
        scrolled()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    // MARK: Scrolling

    /// Puts now 15 minutes in from the channel column (docs/LIVE-TV.md §6.5).
    func scrollToNow(animated: Bool) {
        scroll(to: content.now.addingTimeInterval(-15 * 60), animated: animated)
    }

    private func scroll(to date: Date, animated: Bool) {
        guard !rows.isEmpty else { return }
        let target = layout.x(for: date) - layout.columnWidth
        let maxX = max(0, layout.collectionViewContentSize.width - collectionView.bounds.width)
        let offset = CGPoint(x: min(max(0, target), maxX), y: collectionView.contentOffset.y)
        collectionView.setContentOffset(offset, animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrolled()
    }

    private func scrolled() {
        pinTitles()
        placePill()
        let x = layout.x(for: content.now)
        let offset = collectionView.contentOffset
        let visible = !rows.isEmpty && x >= offset.x + layout.columnWidth && x <= offset.x + collectionView.bounds.width - layout.trailing
        if visible != reportedNowVisible {
            reportedNowVisible = visible
            let report = onNowVisibility
            // Not during a SwiftUI update: the first report comes from the update's layout pass.
            Task { @MainActor in report?(visible) }
        }
        let day = LiveText.day(layout.date(at: offset.x + layout.columnWidth), now: content.now)
        if day != cornerDay {
            cornerDay = day
            for case let corner as GuideCorner in collectionView.visibleSupplementaryViews(ofKind: GuideLayout.cornerKind) {
                configure(corner)
            }
        }
    }

    /// Titles of airings that began left of the visible edge slide in so they stay readable.
    private func pinTitles() {
        let edge = collectionView.contentOffset.x + layout.columnWidth
        for case let cell as AiringCell in collectionView.visibleCells {
            cell.titleShift = max(0, edge - cell.frame.minX)
        }
    }

    private func placeNow(animated: Bool) {
        guard !rows.isEmpty else {
            nowLine.isHidden = true
            nowPill.isHidden = true
            return
        }
        let height = layout.rowsHeight
        let center = CGPoint(x: layout.x(for: content.now), y: layout.metrics.rulerHeight + height / 2)
        nowLine.isHidden = false
        nowLine.bounds = CGRect(x: 0, y: 0, width: 2, height: height)
        if animated {
            UIView.animate(withDuration: 0.3) { self.nowLine.center = center }
        } else {
            nowLine.center = center
        }
        placePill()
    }

    private func placePill() {
        guard !rows.isEmpty else { return }
        let size = nowPill.intrinsicContentSize
        let x = layout.x(for: content.now)
        let offset = collectionView.contentOffset
        nowPill.frame = CGRect(
            x: x - size.width / 2,
            y: offset.y + (layout.metrics.rulerHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        nowPill.isHidden = x - size.width / 2 < offset.x + layout.columnWidth
    }

    // MARK: Content

    private func refreshVisible() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: indexPath) as? AiringCell { configure(cell, at: indexPath) }
        }
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: GuideLayout.channelKind) {
            if let header = collectionView.supplementaryView(forElementKind: GuideLayout.channelKind, at: indexPath) as? ChannelHeader {
                configure(header, row: indexPath.section)
            }
        }
        for case let slot as RulerSlot in collectionView.visibleSupplementaryViews(ofKind: GuideLayout.rulerKind) {
            slot.apply(style?.theme)
        }
        for case let corner as GuideCorner in collectionView.visibleSupplementaryViews(ofKind: GuideLayout.cornerKind) {
            configure(corner)
        }
    }

    private func configure(_ cell: AiringCell, at indexPath: IndexPath) {
        guard let theme = style?.theme, indexPath.section < rows.count, indexPath.item < rows[indexPath.section].count else { return }
        let channel = content.channels[indexPath.section]
        switch rows[indexPath.section][indexPath.item] {
        case .airing(let airing):
            let mark = content.recordings.mark(for: airing)
            cell.show(airing, now: content.now, mark: mark, dimmed: !channel.device.isAlive, theme: theme, reduceMotion: style?.reduceMotion ?? false)
            cell.accessibilityLabel = LiveText.spoken(channel, airing: airing, at: content.now, mark: mark)
            cell.accessibilityHint = airing.isOn(at: content.now) ? "Plays the channel" : "Shows the programme"
            cell.accessibilityCustomActions = customActions(airing, channel: channel)
        case .gap:
            cell.showGap(theme: theme)
            cell.accessibilityLabel = LiveText.spoken(channel, airing: nil, at: content.now, mark: nil)
            cell.accessibilityHint = "Plays the channel"
            cell.accessibilityCustomActions = nil
        }
        cell.titleShift = max(0, collectionView.contentOffset.x + layout.columnWidth - (layout.layoutAttributesForItem(at: indexPath)?.frame.minX ?? 0))
    }

    private func configure(_ header: ChannelHeader, row: Int) {
        guard let theme = style?.theme, row < content.channels.count else { return }
        let channel = content.channels[row]
        header.show(channel, leading: layout.leading, theme: theme, scale: traitCollection.displayScale)
        header.onTap = { [weak self] in self?.actions.play(channel) }
    }

    private func configure(_ corner: GuideCorner) {
        guard let theme = style?.theme else { return }
        corner.show(day: cornerDay, leading: layout.leading, theme: theme, menu: dayMenu())
    }

    /// Now, tonight at 8 and tomorrow morning and evening, as far as the guide reaches.
    private func dayMenu() -> UIMenu {
        let now = content.now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let marks = [(0, 20), (1, 8), (1, 20)].compactMap { day, hour -> Date? in
            guard let date = calendar.date(byAdding: DateComponents(day: day, hour: hour), to: today),
                  date > now, date < content.guide.to else { return nil }
            return date
        }
        var items: [UIMenuElement] = [UIAction(title: "Now", image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
            guard let self else { return }
            scrollToNow(animated: !(style?.reduceMotion ?? false))
        }]
        items += marks.map { date in
            let title = "\(LiveText.day(date, now: now)) \(date.formatted(.dateTime.hour()))"
            return UIAction(title: title) { [weak self] _ in
                guard let self else { return }
                scroll(to: date, animated: !(style?.reduceMotion ?? false))
            }
        }
        return UIMenu(title: "Jump to", children: items)
    }

    private func customActions(_ airing: LiveAiring, channel: LiveChannel) -> [UIAccessibilityCustomAction] {
        var list: [UIAccessibilityCustomAction] = []
        if airing.isOn(at: content.now) {
            list.append(UIAccessibilityCustomAction(name: "Watch") { [weak self] _ in
                self?.actions.play(channel)
                return true
            })
        }
        if content.canRecord, airing.end > content.now, content.recordings.mark(for: airing) == nil {
            list.append(UIAccessibilityCustomAction(name: "Record") { [weak self] _ in
                self?.actions.record(airing, channel)
                return true
            })
        }
        list.append(UIAccessibilityCustomAction(name: "Details") { [weak self] _ in
            self?.actions.open(airing, channel)
            return true
        })
        return list
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows[section].count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AiringCell.reuse, for: indexPath)
        if let cell = cell as? AiringCell { configure(cell, at: indexPath) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        switch kind {
        case GuideLayout.channelKind:
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ChannelHeader.reuse, for: indexPath)
            if let header = view as? ChannelHeader { configure(header, row: indexPath.section) }
            return view
        case GuideLayout.rulerKind:
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: RulerSlot.reuse, for: indexPath)
            if let slot = view as? RulerSlot {
                slot.show(LiveText.time(layout.slotStart(indexPath.item)), theme: style?.theme)
            }
            return view
        default:
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GuideCorner.reuse, for: indexPath)
            if let corner = view as? GuideCorner { configure(corner) }
            return view
        }
    }

    // MARK: Delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let channel = content.channels[indexPath.section]
        switch rows[indexPath.section][indexPath.item] {
        case .airing(let airing) where !airing.isOn(at: content.now):
            actions.open(airing, channel)
        case .airing, .gap:
            actions.play(channel)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, case .airing(let airing) = rows[indexPath.section][indexPath.item] else { return nil }
        let channel = content.channels[indexPath.section]
        let now = content.now
        let canRecord = content.canRecord && airing.end > now && content.recordings.mark(for: airing) == nil
        let favourite = content.favourites.contains(channel.id)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var items: [UIMenuElement] = []
            if airing.isOn(at: now) {
                items.append(UIAction(title: "Watch", image: UIImage(systemName: "play.fill")) { _ in self?.actions.play(channel) })
            }
            if canRecord {
                items.append(UIAction(title: "Record", image: UIImage(systemName: "record.circle")) { _ in self?.actions.record(airing, channel) })
            }
            items.append(UIAction(title: "Details", image: UIImage(systemName: "info.circle")) { _ in self?.actions.open(airing, channel) })
            items.append(UIAction(
                title: favourite ? "Remove from Favourites" : "Add to Favourites",
                image: UIImage(systemName: favourite ? "star.slash" : "star")
            ) { _ in self?.actions.toggleFavourite(channel) })
            return UIMenu(children: items)
        }
    }
}

// MARK: - Layout

/// Places airings by time: x from the start, width from the length; one row per channel. The channel
/// column, the ruler and their corner are pinned by placing them at the scroll offset on every bounds
/// change; the airings' frames are built once per guide.
@MainActor
final class GuideLayout: UICollectionViewLayout {
    static let channelKind = "guide.channel"
    static let rulerKind = "guide.ruler"
    static let cornerKind = "guide.corner"

    struct Metrics: Equatable {
        var channelWidth: CGFloat = Size.gridMin
        var pointsPerMinute: CGFloat = 6
        var rowHeight: CGFloat = 64
        var rulerHeight: CGFloat = 32
        var gap: CGFloat = Space.s1

        init() {}

        /// Phones: 104 pt column and 6 pt a minute; regular width: 160 pt and 8 (docs/LIVE-TV.md §6.3).
        /// Rows fit a title and a time line at the current text size.
        init(regular: Bool, typeSize: DynamicTypeSize) {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
            let title = GuideFonts.title(traits).lineHeight
            let caption = GuideFonts.caption(traits).lineHeight
            channelWidth = regular ? 160 : Size.gridMin
            pointsPerMinute = regular ? 8 : 6
            rowHeight = max(Size.rowMin, ceil(title + 2 + caption + 2 * Space.s2)) + Space.s1
            rulerHeight = max(32, ceil(caption + Space.s3))
        }
    }

    private(set) var metrics = Metrics()
    private(set) var origin = Date()
    private(set) var minutes: Double = 0
    private(set) var leading: CGFloat = 0
    private(set) var trailing: CGFloat = 0
    private var spans: [[(Double, Double)]] = []
    private var frames: [[CGRect]] = []
    private var cached: [[UICollectionViewLayoutAttributes]] = []
    private var size: CGSize = .zero
    private var dirty = true

    var columnWidth: CGFloat { leading + metrics.channelWidth }
    var rowsHeight: CGFloat { CGFloat(spans.count) * metrics.rowHeight }
    private var slotWidth: CGFloat { 30 * metrics.pointsPerMinute }
    private var slotCount: Int { Int((minutes / 30).rounded(.up)) }

    func configure(metrics: Metrics, origin: Date, minutes: Double, spans: [[(Double, Double)]]) {
        self.metrics = metrics
        self.origin = origin
        self.minutes = minutes
        self.spans = spans
        dirty = true
        invalidateLayout()
    }

    func setInsets(leading: CGFloat, trailing: CGFloat) {
        guard leading != self.leading || trailing != self.trailing else { return }
        self.leading = leading
        self.trailing = trailing
        dirty = true
        invalidateLayout()
    }

    func x(for date: Date) -> CGFloat {
        columnWidth + CGFloat(date.timeIntervalSince(origin) / 60) * metrics.pointsPerMinute
    }

    func date(at x: CGFloat) -> Date {
        origin.addingTimeInterval(Double((x - columnWidth) / metrics.pointsPerMinute) * 60)
    }

    func slotStart(_ slot: Int) -> Date {
        origin.addingTimeInterval(Double(slot) * 30 * 60)
    }

    override func prepare() {
        super.prepare()
        guard dirty else { return }
        dirty = false
        let ppm = metrics.pointsPerMinute
        let half = metrics.gap / 2
        let left = columnWidth
        frames = spans.enumerated().map { row, items in
            let y = metrics.rulerHeight + CGFloat(row) * metrics.rowHeight
            return items.map { start, end in
                let minX = left + CGFloat(max(start, 0)) * ppm
                let maxX = left + CGFloat(min(end, minutes)) * ppm
                return CGRect(x: minX + half, y: y + half, width: max(0, maxX - minX - metrics.gap), height: metrics.rowHeight - metrics.gap)
            }
        }
        cached = frames.enumerated().map { row, rects in
            rects.enumerated().map { item, rect in
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: row))
                attributes.frame = rect
                return attributes
            }
        }
        size = CGSize(width: left + CGFloat(minutes) * ppm + trailing, height: metrics.rulerHeight + rowsHeight)
    }

    override var collectionViewContentSize: CGSize { size }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        true
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        let first = max(0, Int(((rect.minY - metrics.rulerHeight) / metrics.rowHeight).rounded(.down)))
        let last = min(frames.count - 1, Int(((rect.maxY - metrics.rulerHeight) / metrics.rowHeight).rounded(.down)))
        if first <= last {
            for row in first...last {
                let rects = frames[row]
                var index = Self.firstIndex(in: rects, endingAfter: rect.minX)
                while index < rects.count, rects[index].minX < rect.maxX {
                    result.append(cached[row][index])
                    index += 1
                }
                result.append(header(row))
            }
        }
        let firstSlot = max(0, Int(((rect.minX - columnWidth) / slotWidth).rounded(.down)))
        let lastSlot = min(slotCount - 1, Int(((rect.maxX - columnWidth) / slotWidth).rounded(.down)))
        if firstSlot <= lastSlot {
            for slot in firstSlot...lastSlot { result.append(ruler(slot)) }
        }
        result.append(corner())
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section < cached.count, indexPath.item < cached[indexPath.section].count else { return nil }
        return cached[indexPath.section][indexPath.item]
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case Self.channelKind: indexPath.section < spans.count ? header(indexPath.section) : nil
        case Self.rulerKind: indexPath.item < slotCount ? ruler(indexPath.item) : nil
        case Self.cornerKind: corner()
        default: nil
        }
    }

    private var offset: CGPoint { collectionView?.contentOffset ?? .zero }

    private func header(_ row: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.channelKind, with: IndexPath(item: 0, section: row))
        attributes.frame = CGRect(x: offset.x, y: metrics.rulerHeight + CGFloat(row) * metrics.rowHeight, width: columnWidth, height: metrics.rowHeight)
        attributes.zIndex = 20
        return attributes
    }

    private func ruler(_ slot: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.rulerKind, with: IndexPath(item: slot, section: 0))
        attributes.frame = CGRect(x: columnWidth + CGFloat(slot) * slotWidth, y: offset.y, width: slotWidth, height: metrics.rulerHeight)
        attributes.zIndex = 20
        return attributes
    }

    private func corner() -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.cornerKind, with: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: offset.x, y: offset.y, width: columnWidth, height: metrics.rulerHeight)
        attributes.zIndex = 30
        return attributes
    }

    /// The first rect whose right edge is past `x`; rects are sorted and do not overlap.
    private static func firstIndex(in rects: [CGRect], endingAfter x: CGFloat) -> Int {
        var low = 0
        var high = rects.count
        while low < high {
            let middle = (low + high) / 2
            if rects[middle].maxX <= x { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

// MARK: - Cells

/// The grid's type: `label` and `caption` of the type scale, at a given text size.
enum GuideFonts {
    static func title(_ traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .medium), compatibleWith: traits)
    }

    static func caption(_ traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
    }

    static func badge(_ traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11, weight: .bold), compatibleWith: traits)
    }
}

/// One airing: on now on raised glass, later on glass, earlier bare with quieter text.
private final class AiringCell: UICollectionViewCell {
    static let reuse = "airing"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let badge = UILabel()
    private let glyph = UIImageView()
    private var reduceMotion = false

    /// How far the text slides right to stay on screen.
    var titleShift: CGFloat = 0 {
        didSet { if titleShift != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = Radius.control
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 0
        contentView.clipsToBounds = true
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
            contentView.addSubview(label)
        }
        badge.text = "NEW"
        badge.textAlignment = .center
        badge.layer.borderWidth = 1
        badge.layer.cornerRadius = 4
        badge.layer.cornerCurve = .continuous
        contentView.addSubview(badge)
        glyph.contentMode = .scaleAspectFit
        contentView.addSubview(glyph)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ airing: LiveAiring, now: Date, mark: RecordingMark?, dimmed: Bool, theme: Theme, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let traits = traitCollection
        let past = airing.end <= now
        let onNow = airing.isOn(at: now)
        titleLabel.font = GuideFonts.title(traits)
        detailLabel.font = GuideFonts.caption(traits)
        badge.font = GuideFonts.badge(traits)
        titleLabel.text = airing.title
        detailLabel.text = onNow ? LiveText.left(airing, at: now) : LiveText.range(airing)
        titleLabel.textColor = past ? theme.roles.ink2.uiColor : theme.roles.ink.uiColor
        detailLabel.textColor = theme.roles.ink2.uiColor
        contentView.backgroundColor = onNow ? theme.roles.glassRaised.uiColor : past ? .clear : theme.roles.glass.uiColor
        contentView.layer.borderColor = theme.roles.edge.uiColor.cgColor
        contentView.layer.borderWidth = onNow || past ? 0 : 1
        badge.isHidden = !airing.isNew || past
        badge.textColor = theme.roles.ink.uiColor
        badge.layer.borderColor = theme.roles.ink2.uiColor.cgColor
        if let mark {
            glyph.isHidden = false
            glyph.image = UIImage(systemName: mark.symbol, withConfiguration: UIImage.SymbolConfiguration(font: detailLabel.font, scale: .large))
            glyph.tintColor = mark.uiColor(in: theme)
            if mark == .recording && !reduceMotion {
                glyph.addSymbolEffect(.pulse, options: .repeating)
            } else {
                glyph.removeAllSymbolEffects()
            }
        } else {
            glyph.isHidden = true
            glyph.removeAllSymbolEffects()
        }
        contentView.alpha = dimmed ? 0.5 : 1
        setNeedsLayout()
    }

    func showGap(theme: Theme) {
        titleLabel.font = GuideFonts.title(traitCollection)
        detailLabel.font = GuideFonts.caption(traitCollection)
        titleLabel.text = "No guide data"
        titleLabel.textColor = theme.roles.ink2.uiColor
        detailLabel.text = nil
        contentView.backgroundColor = .clear
        contentView.layer.borderColor = theme.roles.edge.uiColor.cgColor
        contentView.layer.borderWidth = 1
        badge.isHidden = true
        glyph.isHidden = true
        glyph.removeAllSymbolEffects()
        contentView.alpha = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let detailHeight = ceil(detailLabel.font.lineHeight)
        let top = max(Space.s2, (bounds.height - titleHeight - 2 - detailHeight) / 2)
        var right = bounds.maxX - Space.s2
        let roomy = bounds.width >= 96
        if !glyph.isHidden {
            let side = ceil(detailHeight * 1.1)
            glyph.frame = CGRect(x: right - side, y: top + (titleHeight - side) / 2, width: side, height: side)
            glyph.alpha = roomy ? 1 : 0
            if roomy { right = glyph.frame.minX - Space.s1 }
        }
        if !badge.isHidden {
            let text = badge.intrinsicContentSize
            let size = CGSize(width: ceil(text.width) + 8, height: ceil(text.height) + 2)
            badge.frame = CGRect(x: right - size.width, y: top + (titleHeight - size.height) / 2, width: size.width, height: size.height)
            badge.alpha = roomy ? 1 : 0
            if roomy { right = badge.frame.minX - Space.s1 }
        }
        let left = Space.s3 + min(titleShift, max(0, bounds.width - 72))
        titleLabel.frame = CGRect(x: left, y: top, width: max(0, right - left), height: titleHeight)
        detailLabel.frame = CGRect(x: left, y: top + titleHeight + 2, width: max(0, bounds.maxX - Space.s3 - left), height: detailHeight)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // Press feedback (DESIGN §9): .97 over 90 ms, or a dimmed wash under Reduce Motion.
            if reduceMotion {
                contentView.layer.opacity = isHighlighted ? 0.8 : 1
            } else {
                UIView.animate(withDuration: 0.09, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
                }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        transform = .identity
        contentView.layer.opacity = 1
        titleShift = 0
    }
}

/// A channel in the pinned column: logo tile, number and call sign. A tap plays it.
private final class ChannelHeader: UICollectionReusableView {
    static let reuse = "channel"

    var onTap: (() -> Void)?

    private let tile = UIView()
    private let logo = UIImageView()
    private let fallback = UILabel()
    private let number = UILabel()
    private let callSign = UILabel()
    private let rule = UIView()
    private var leading: CGFloat = 0
    private var logoKey: String?
    private var logoTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tile.layer.cornerRadius = ChannelLogo.radius(side: 40)
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = 1
        tile.clipsToBounds = true
        logo.contentMode = .scaleAspectFit
        fallback.textAlignment = .center
        fallback.adjustsFontSizeToFitWidth = true
        fallback.minimumScaleFactor = 0.5
        tile.addSubview(fallback)
        tile.addSubview(logo)
        addSubview(tile)
        for label in [number, callSign] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            addSubview(label)
        }
        addSubview(rule)
        isAccessibilityElement = true
        accessibilityTraits = [.button, .header]
        accessibilityHint = "Plays the channel"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ channel: LiveChannel, leading: CGFloat, theme: Theme, scale: CGFloat) {
        self.leading = leading
        let traits = traitCollection
        backgroundColor = theme.roles.canvas.uiColor
        tile.backgroundColor = theme.roles.glass.uiColor
        tile.layer.borderColor = theme.roles.edge.uiColor.cgColor
        rule.backgroundColor = theme.roles.edge.uiColor
        number.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), compatibleWith: traits)
        number.textColor = theme.roles.ink.uiColor
        number.text = channel.number
        callSign.font = GuideFonts.caption(traits)
        callSign.textColor = theme.roles.ink2.uiColor
        callSign.text = channel.callSign
        fallback.font = .systemFont(ofSize: 10, weight: .bold)
        fallback.textColor = theme.roles.ink2.uiColor
        fallback.text = channel.callSign.isEmpty ? channel.number : channel.callSign
        accessibilityLabel = "\(channel.label), \(channel.title)" + (channel.device.isAlive ? "" : ", tuner not responding")
        alpha = channel.device.isAlive ? 1 : 0.5
        loadLogo(channel, scale: scale)
        setNeedsLayout()
    }

    private func loadLogo(_ channel: LiveChannel, scale: CGFloat) {
        guard let request = LogoImages.request(channel, side: 40, scale: scale) else {
            logoTask?.cancel()
            logoKey = nil
            setLogo(nil)
            return
        }
        guard request.cacheKey != logoKey else { return }
        logoTask?.cancel()
        logoKey = request.cacheKey
        if let cached = ImagePipeline.shared.cachedImage(request) {
            setLogo(cached)
            return
        }
        setLogo(nil)
        let key = request.cacheKey
        logoTask = Task { [weak self] in
            let image = try? await ImagePipeline.shared.image(request, library: nil)
            guard let self, !Task.isCancelled, logoKey == key else { return }
            setLogo(image)
        }
    }

    private func setLogo(_ image: UIImage?) {
        logo.image = image
        logo.isHidden = image == nil
        fallback.isHidden = image != nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 40
        let gap = Space.s1
        let height = bounds.height - gap
        let x = leading + Space.s2
        tile.frame = CGRect(x: x, y: gap / 2 + (height - side) / 2, width: side, height: side)
        let inset = side * LogoImages.inset
        logo.frame = tile.bounds.insetBy(dx: inset, dy: inset)
        fallback.frame = tile.bounds.insetBy(dx: 3, dy: 3)
        let textX = tile.frame.maxX + Space.s2
        let width = max(0, bounds.width - textX - Space.s2)
        let numberHeight = ceil(number.font.lineHeight)
        let callHeight = ceil(callSign.font.lineHeight)
        let top = gap / 2 + (height - numberHeight - callHeight) / 2
        number.frame = CGRect(x: textX, y: top, width: width, height: numberHeight)
        callSign.frame = CGRect(x: textX, y: top + numberHeight, width: width, height: callHeight)
        rule.frame = CGRect(x: bounds.width - 1 / max(1, traitCollection.displayScale), y: 0, width: 1 / max(1, traitCollection.displayScale), height: bounds.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    @objc private func tapped() {
        Haptics.selection()
        onTap?()
    }
}

/// A half hour of the time ruler.
private final class RulerSlot: UICollectionReusableView {
    static let reuse = "ruler"

    private let label = UILabel()
    private let tick = UIView()
    private let rule = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        addSubview(tick)
        addSubview(rule)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ text: String, theme: Theme?) {
        label.text = text
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), compatibleWith: traitCollection)
        apply(theme)
        setNeedsLayout()
    }

    func apply(_ theme: Theme?) {
        guard let theme else { return }
        backgroundColor = theme.roles.canvas.uiColor
        label.textColor = theme.roles.ink2.uiColor
        tick.backgroundColor = theme.roles.edge.uiColor
        rule.backgroundColor = theme.roles.edge.uiColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hairline = 1 / max(1, traitCollection.displayScale)
        tick.frame = CGRect(x: 0, y: bounds.height * 0.5, width: hairline, height: bounds.height * 0.5)
        rule.frame = CGRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline)
        label.frame = CGRect(x: Space.s2, y: 0, width: bounds.width - Space.s3, height: bounds.height)
    }
}

/// The top-left corner: the visible day, which opens the day menu.
private final class GuideCorner: UICollectionReusableView {
    static let reuse = "corner"

    private let button = UIButton(type: .system)
    private let rule = UIView()
    private var leading: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "livetv.day"
        button.contentHorizontalAlignment = .leading
        addSubview(button)
        addSubview(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(day: String, leading: CGFloat, theme: Theme, menu: UIMenu) {
        self.leading = leading
        backgroundColor = theme.roles.canvas.uiColor
        rule.backgroundColor = theme.roles.edge.uiColor
        var configuration = UIButton.Configuration.plain()
        configuration.title = day
        configuration.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = Space.s1
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Space.s2, bottom: 0, trailing: Space.s1)
        configuration.baseForegroundColor = theme.roles.ink.uiColor
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [traits = traitCollection] attributes in
            var attributes = attributes
            attributes.font = GuideFonts.title(traits)
            return attributes
        }
        button.configuration = configuration
        button.menu = menu
        button.accessibilityLabel = "\(day), jump to a time"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hairline = 1 / max(1, traitCollection.displayScale)
        // The button keeps the 48 pt target even where the ruler is shorter.
        let height = max(bounds.height, Size.target)
        button.frame = CGRect(x: leading, y: (bounds.height - height) / 2, width: bounds.width - leading, height: height)
        rule.frame = CGRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        button.frame.contains(point)
    }
}

/// The clock on the ruler where the now line meets it.
private final class NowPill: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .bold))
        adjustsFontForContentSizeCategory = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ theme: Theme) {
        backgroundColor = theme.roles.live.uiColor
        textColor = theme.roles.canvas.uiColor
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: ceil(size.width) + Space.s3, height: ceil(size.height) + Space.s1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
