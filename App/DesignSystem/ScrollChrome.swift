import SwiftUI

/// How a page's navigation bar meets the content scrolling under it (DESIGN §7.1), after Apollo's header
/// styles. Soft and Hard are the system's own scroll edge effects; Blur frosts the content under the bar
/// in the theme's canvas, fading out below it.
enum HeaderStyle: String, CaseIterable, Identifiable {
    case soft, hard, blur

    var id: Self { self }

    var name: String {
        switch self {
        case .soft: "Soft"
        case .hard: "Hard"
        case .blur: "Blur"
        }
    }
}

/// What the tab bar does while a browse page scrolls down (DESIGN §7).
enum TabBarBehavior: String, CaseIterable, Identifiable {
    case always, hide, minimise

    var id: Self { self }

    var name: String {
        switch self {
        case .always: "Always Show"
        case .hide: "Hide on Scroll"
        case .minimise: "Minimise on Scroll"
        }
    }
}

/// Hide on Scroll's state for one browse tab: whether its tab bar is away. Each tab's stack owns one, so a
/// push or a pop can bring the bar back.
@Observable @MainActor
final class TabBarScroll {
    var hidden = false

    /// Brings the bar back, as the page arriving after a push or a pop does.
    func show(reduceMotion: Bool) {
        guard hidden else { return }
        withAnimation(Motion.tabBar(reduceMotion: reduceMotion)) { hidden = false }
    }
}

extension View {
    /// The header style on this scroll view. `band: false` keeps a page on system glass, such as a partial
    /// sheet, on the soft edge, since Blur's band is drawn in the canvas.
    func scrollHeader(band: Bool = true) -> some View {
        modifier(ScrollHeader(band: band))
    }

    /// Lets this scroll view, a browse page's main one, slide the tab bar away under Hide on Scroll.
    func tabBarFollowsScroll() -> some View {
        modifier(TabBarFollowsScroll())
    }
}

private struct ScrollHeader: ViewModifier {
    let band: Bool

    @Environment(ThemeStore.self) private var store
    @State private var shape = BandShape.rest

    func body(content: Content) -> some View {
        let blur = band && store.headerStyle == .blur
        content
            // Never branched on: a style change must not rebuild the page under it.
            .scrollEdgeEffectStyle(store.headerStyle == .hard ? ScrollEdgeEffectStyle.hard : .soft, for: .top)
            .scrollEdgeEffectHidden(blur, for: .top)
            .onScrollGeometryChange(for: BandShape.self) { geometry in
                blur ? BandShape(geometry) : .rest
            } action: { _, new in
                shape = new
            }
            .overlay {
                if blur {
                    HeaderBand(inset: shape.inset, opacity: Double(shape.step) / Double(BandShape.steps))
                }
            }
    }
}

/// What the blur band needs from the scroll view, in whole points and 4 pt steps so the band redraws a few
/// times as the content first passes under the bar and not on every frame after.
private struct BandShape: Equatable {
    /// The bar's height over the content: status bar, navigation bar and any bar pinned under it.
    var inset: CGFloat
    /// How far the content has gone under the bar, 0 at rest to `steps` 24 pt in.
    var step: Int

    static let steps = 6
    static let rest = BandShape(inset: 0, step: 0)

    init(inset: CGFloat, step: Int) {
        self.inset = inset
        self.step = step
    }

    init(_ geometry: ScrollGeometry) {
        let top = geometry.contentInsets.top
        let under = geometry.contentOffset.y + top
        inset = top.isFinite ? max(top, 0).rounded() : 0
        step = under.isFinite ? min(max(Int(under / Space.s1), 0), Self.steps) : 0
    }
}

/// Blur's band: the content under the bar frosted and tinted with the canvas, solid behind the status bar
/// and the bar and fading out over 24 pt below it. Reduce Transparency draws the canvas instead.
private struct HeaderBand: View {
    let inset: CGFloat
    let opacity: Double

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let height = inset + Space.s6
        VStack(spacing: 0) {
            fill
                .frame(height: height)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: inset / height),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .opacity(opacity)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fill: some View {
        if reduceTransparency {
            theme.canvas
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay { theme.canvas.opacity(0.5) }
        }
    }
}

private struct TabBarFollowsScroll: ViewModifier {
    @Environment(ThemeStore.self) private var store
    @Environment(TabBarScroll.self) private var bar: TabBarScroll?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tracker = ScrollDirection()

    func body(content: Content) -> some View {
        // VoiceOver keeps the bar: its tabs must stay reachable without scrolling back up.
        let active = bar != nil && store.tabBar == .hide && !voiceOver
        content
            .onScrollPhaseChange { _, phase in
                tracker.userDriven = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: ScrollStep.self) { geometry in
                active ? ScrollStep(geometry) : .top
            } action: { _, step in
                if let hidden = tracker.update(step) { show(!hidden) }
            }
            .onChange(of: active) { _, on in
                if !on { show(true) }
            }
    }

    private func show(_ shown: Bool) {
        guard let bar, bar.hidden == shown else { return }
        withAnimation(Motion.tabBar(reduceMotion: reduceMotion)) { bar.hidden = !shown }
    }
}

/// The scroll position in 4 pt steps from the top, and whether the end is close.
private struct ScrollStep: Equatable {
    var step: Int
    var nearEnd: Bool

    static let top = ScrollStep(step: 0, nearEnd: false)

    init(step: Int, nearEnd: Bool) {
        self.step = step
        self.nearEnd = nearEnd
    }

    init(_ geometry: ScrollGeometry) {
        let offset = geometry.contentOffset.y + geometry.contentInsets.top
        let end = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            - geometry.containerSize.height
        step = offset.isFinite ? max(Int(offset / Space.s1), 0) : 0
        // The bar going or coming changes the bottom inset by up to about 90 pt, which moves an offset
        // pinned to the end and would read as a scroll; within three touch targets of the end the bar stays.
        nearEnd = end.isFinite && offset.isFinite && end - offset < Size.target * 3
    }
}

/// Which way the user is scrolling and how far since it last turned. A plain class in state, so the
/// per-frame bookkeeping never invalidates a view; only a change of `hidden` does.
@MainActor
private final class ScrollDirection {
    /// A finger or a fling moves the page; programmatic scrolls and layout changes never move the bar. Each
    /// drag measures its travel from where it starts.
    var userDriven = false {
        didSet { if userDriven, !oldValue { turn = last ?? 0 } }
    }
    private var last: Int?
    private var turn = 0
    private var down = true

    /// 24 pt in one direction moves the bar; within 32 pt of the top it always shows.
    private static let travel = Int(Space.s6 / Space.s1)
    private static let topZone = Int(Space.s7 / Space.s1)

    /// The bar's new state, or nil to leave it.
    func update(_ position: ScrollStep) -> Bool? {
        defer { last = position.step }
        if position.step <= Self.topZone { return false }
        guard userDriven, !position.nearEnd, let last else { return nil }
        if position.step > last {
            if !down { down = true; turn = last }
            return position.step - turn >= Self.travel ? true : nil
        }
        if position.step < last {
            if down { down = false; turn = last }
            return turn - position.step >= Self.travel ? false : nil
        }
        return nil
    }
}
