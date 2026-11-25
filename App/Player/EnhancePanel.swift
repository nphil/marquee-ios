import SwiftUI

/// A slider of the Enhance Picture page being dragged: while one is, the page and the chrome step aside and the
/// player draws this slider alone, in a capsule over where the slider was, so the picture can be judged.
struct EnhanceDrag: Equatable {
    var title: String
    var value: Double
    /// The slider's track on screen, in global coordinates.
    var track: CGRect
}

/// The Enhance Picture page of the More menu, as a panel over the player and not a popover page: a system popover
/// keeps its arrow and shadow, which would stay over the picture while a slider is dragged. It sits above the
/// bottom controls, like the popover, in a system material, and takes the popover's metrics and text styles.
struct EnhancePanel: View {
    let model: PlayerModel
    let screenWidth: CGFloat
    let bottomInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 1000
    @State private var headerHeight: CGFloat = MenuMetrics.rowHeight

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                // Outside the panel a tap closes it; the picture below does not answer it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeEnhance() }
                    .accessibilityHidden(true)
                panel(room: max(0, proxy.size.height - bottomInset - Space.s2))
                    .padding(.trailing, Space.inset)
                    .padding(.bottom, bottomInset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityAction(.escape) { model.closeEnhance() }
    }

    private var setting: PictureEnhance { model.pictureEnhance }

    private var unavailable: String? {
        if setting.upscaler != .off, case .unavailable(let reason)? = model.enhance?.state { return reason.message }
        return nil
    }

    private var width: CGFloat { min(300, max(240, screenWidth * 0.7)) }

    /// The page, which keeps its place and state while a slider is dragged: it is only not drawn, so the finger
    /// that started the drag stays on the slider that tracks it.
    private func panel(room: CGFloat) -> some View {
        let hidden = model.enhanceDragging
        return VStack(alignment: .leading, spacing: 0) {
            MenuHeader(title: "Enhance Picture") {
                Haptics.impact(.light)
                model.closeEnhance()
                // Back to the More popover, once the panel has let go of the player's menu hold.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    model.showsMore = true
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            // The header stays; the rows scroll under it only when the screen is truly short.
            ScrollView {
                rows
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.vertical, MenuMetrics.edge, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .scrollIndicatorsFlash(onAppear: true)
            .frame(height: max(0, min(contentHeight + 2 * MenuMetrics.edge, room - headerHeight)))
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        }
        .opacity(hidden ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.enhance.panel")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let unavailable {
                Text(unavailable)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MenuMetrics.margin)
                    .padding(.vertical, Space.s2)
            }
            ForEach(PictureEnhance.Upscaler.allCases, id: \.self) { upscaler in
                choice(upscaler)
            }
            if setting.upscaler != .off {
                Divider().padding(.leading, MenuMetrics.margin)
                EnhanceSliderRow(
                    model: model, title: "Sharpen", id: "player.enhanceSharpen", value: setting.sharpen, enabled: unavailable == nil
                ) { $0.sharpen = $1 }
                EnhanceSliderRow(
                    model: model, title: "Deband", id: "player.enhanceDeband", value: setting.deband, enabled: unavailable == nil
                ) { $0.deband = $1 }
            }
        }
    }

    private func choice(_ upscaler: PictureEnhance.Upscaler) -> some View {
        let isOn = setting.upscaler == upscaler
        return Button {
            Haptics.impact(.light)
            var next = setting
            next.upscaler = upscaler
            model.setEnhance(next)
        } label: {
            HStack(spacing: Space.s3) {
                Text(upscaler.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, MenuMetrics.margin)
            .padding(.vertical, MenuMetrics.vertical)
            .frame(minHeight: MenuMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(upscaler.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("player.enhance.\(upscaler.rawValue)")
    }
}

// MARK: - Slider

/// One slider of the page: its label and percentage on one line, the track under it. Touching the track hands the
/// drag to the player, which draws it alone in a capsule (`EnhanceDragCapsule`) and brings the page back on release.
/// VoiceOver adjusts it in place and the page stays.
private struct EnhanceSliderRow: View {
    let model: PlayerModel
    let title: String
    let id: String
    let value: Double
    let enabled: Bool
    let set: (inout PictureEnhance, Double) -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var track = CGRect.zero
    @GestureState private var touching = false

    var body: some View {
        let percent = Int((value * 100).rounded())
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            EnhanceTrack(value: value)
                .frame(height: EnhanceTrack.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { track = $0 }
                .contentShape(Rectangle())
                .gesture(drag)
        }
        .padding(.horizontal, MenuMetrics.margin)
        .padding(.vertical, MenuMetrics.vertical)
        .frame(minHeight: MenuMetrics.rowHeight)
        .opacity(enabled ? 1 : 0.5)
        .allowsHitTesting(enabled)
        .onChange(of: touching) { _, isTouching in
            if !isTouching { model.enhanceDrag = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(percent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(min(1, value + 0.05))
            case .decrement: commit(max(0, value - 0.05))
            @unknown default: break
            }
        }
        .accessibilityIdentifier(id)
    }

    /// The finger's place along the track is the value, so the thumb is under it from the first touch.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { gesture in
                let travel = max(1, track.width - EnhanceTrack.thumb)
                let next = min(1, max(0, (gesture.location.x - track.minX - EnhanceTrack.thumb / 2) / travel))
                commit(next)
                // VoiceOver users never lose the page under them.
                if !voiceOver { model.enhanceDrag = EnhanceDrag(title: title, value: next, track: track) }
            }
    }

    private func commit(_ next: Double) {
        var setting = model.pictureEnhance
        set(&setting, next)
        model.setEnhance(setting)
    }
}

/// The track and thumb of an Enhance slider, drawn the same in the page and in the capsule.
struct EnhanceTrack: View {
    static let height: CGFloat = 32
    static let thumb: CGFloat = 28
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            let travel = max(0, proxy.size.width - Self.thumb)
            let x = travel * min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 4)
                Capsule().fill(.tint).frame(width: x + Self.thumb / 2, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// The dragged slider alone, on its own glass capsule where the slider was, drawn by the player over everything
/// else. Its track has the page slider's width and place, so the thumb stays under the finger. It never takes a
/// touch: the page's slider still owns the gesture.
struct EnhanceDragCapsule: View {
    let drag: EnhanceDrag
    @ScaledMetric(relativeTo: .subheadline) private var line: CGFloat = 20

    private static let side = Space.s5

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            // The capsule's track centre lands on the touched track's centre.
            let above = Space.s3 + line + Space.s2 + EnhanceTrack.height / 2
            let top = max(Space.s2, drag.track.midY - origin.y - above)
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack {
                    Text(drag.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text("\(Int((drag.value * 100).rounded()))%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(height: line)
                EnhanceTrack(value: drag.value)
                    .frame(height: EnhanceTrack.height)
            }
            .padding(.horizontal, Self.side)
            .padding(.vertical, Space.s3)
            .frame(width: drag.track.width + 2 * Self.side)
            .glassEffect(.regular, in: Capsule())
            .offset(x: drag.track.minX - origin.x - Self.side, y: top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
