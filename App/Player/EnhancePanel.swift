import SwiftUI

/// The Enhance Picture page of the More menu, as a panel over the player and not a popover page: while a
/// slider is dragged everything but that slider fades, and a system popover keeps its arrow and shadow, which
/// would stay over the picture. It sits above the bottom controls, like the popover, in the theme's surface.
struct EnhancePanel: View {
    let model: PlayerModel
    let screenWidth: CGFloat
    let bottomInset: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var dragging: Field?

    private enum Field { case sharpen, deband }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Outside the panel a tap closes it; the picture below does not answer it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.closeEnhance() }
                .accessibilityHidden(true)
            panel
                .padding(.trailing, Space.inset)
                .padding(.bottom, bottomInset)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2), value: dragging)
        .accessibilityAction(.escape) { model.closeEnhance() }
    }

    private var setting: PictureEnhance { model.pictureEnhance }

    private var unavailable: String? {
        if setting.upscaler != .off, case .unavailable(let reason)? = model.enhance?.state { return reason.message }
        return nil
    }

    private var width: CGFloat { min(300, max(240, screenWidth * 0.7)) }

    private var panel: some View {
        let hides = dragging != nil && !voiceOver
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.impact(.light)
                model.closeEnhance()
                // Back to the More popover, once the panel has let go of the player's menu hold.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    model.showsMore = true
                }
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.backward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text("Enhance Picture")
                        .textRole(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.s4)
                .frame(minHeight: Size.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enhance Picture")
            .accessibilityHint("Back")
            .opacity(hides ? 0 : 1)
            Divider().overlay(theme.edge).opacity(hides ? 0 : 1)
            if let unavailable {
                Text(unavailable)
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
                    .opacity(hides ? 0 : 1)
            }
            ForEach(PictureEnhance.Upscaler.allCases, id: \.self) { upscaler in
                choice(upscaler)
                    .opacity(hides ? 0 : 1)
            }
            if setting.upscaler != .off {
                Divider().overlay(theme.edge).opacity(hides ? 0 : 1)
                slider("Sharpen", id: "player.enhanceSharpen", field: .sharpen, value: setting.sharpen) { $0.sharpen = $1 }
                slider("Deband", id: "player.enhanceDeband", field: .deband, value: setting.deband) { $0.deband = $1 }
            }
        }
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(theme.sheet)
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(theme.edge, lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                .opacity(hides ? 0 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.enhance.panel")
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
                    .textRole(.body)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(minHeight: Size.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(upscaler.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("player.enhance.\(upscaler.rawValue)")
    }

    private func slider(_ title: String, id: String, field: Field, value: Double, set: @escaping (inout PictureEnhance, Double) -> Void) -> some View {
        let percent = Int((value * 100).rounded())
        let hidden = dragging != nil && dragging != field && !voiceOver
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .textRole(.body)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .textRole(.body)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
            }
            Slider(
                value: Binding(get: { value }, set: { new in
                    var next = setting
                    set(&next, new)
                    model.setEnhance(next)
                }),
                in: 0...1
            ) { editing in
                dragging = editing ? field : nil
                model.enhanceDragging = editing
            }
            .tint(theme.accent)
            .disabled(unavailable != nil)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .frame(minHeight: Size.target)
        .opacity(hidden ? 0 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(percent) percent")
        .accessibilityIdentifier(id)
    }
}
