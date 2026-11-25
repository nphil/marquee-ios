import LumaRemoteKit
import MarqueeCore
import SwiftUI

/// Arranging the panel: the layout is outlined and each module can be hidden, hidden modules come back from a tray
/// along the foot, and eight handles resize the panel. A finger anywhere else carries it. The keys under all this
/// are inert, and VoiceOver reaches the moves and resizes as actions on the panel.
struct RemoteArrange: View {
    let size: CGSize
    let layout: RemoteLayout
    /// The modules that are off, to put back from the tray.
    let hidden: [RemoteModule]
    let tray: Bool

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage

    var body: some View {
        let remote = session.remote
        ZStack(alignment: .topLeading) {
            surface
            ForEach(Array(PanelHandle.all.enumerated()), id: \.offset) { _, handle in
                ResizeHandle(handle: handle, size: size)
            }
            Outline(rect: layout.pad)
            ForEach(layout.strips, id: \.strip) { placement in
                ForEach(placement.moduleRects, id: \.module) { item in
                    Outline(rect: item.rect)
                    RemoveBadge(module: item.module, rect: item.rect) {
                        remote.setModules(remote.modules.subtracting([item.module]))
                    }
                }
            }
            if tray {
                ModuleTray(
                    hidden: hidden,
                    dropped: layout.dropped,
                    rect: CGRect(x: layout.area.minX, y: layout.area.maxY, width: layout.area.width, height: RemoteMetrics.tray)
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Takes the touches the keys would, and carries the panel under a finger.
    private var surface: some View {
        Color.clear
            .contentShape(Rectangle())
            .movesPanel()
            .accessibilityElement()
            .accessibilityLabel("Remote panel")
            .accessibilityHint("Arranging. The actions move and resize it.")
            .accessibilityAction(named: Text("Move left")) { nudge(-1, 0) }
            .accessibilityAction(named: Text("Move right")) { nudge(1, 0) }
            .accessibilityAction(named: Text("Move up")) { nudge(0, -1) }
            .accessibilityAction(named: Text("Move down")) { nudge(0, 1) }
            .accessibilityAction(named: Text("Wider")) { resize(PanelHandle(right: true), 1, 0) }
            .accessibilityAction(named: Text("Narrower")) { resize(PanelHandle(right: true), -1, 0) }
            .accessibilityAction(named: Text("Taller")) { resize(PanelHandle(bottom: true), 0, 1) }
            .accessibilityAction(named: Text("Shorter")) { resize(PanelHandle(bottom: true), 0, -1) }
    }

    /// One step of a VoiceOver action is one touch target.
    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        stage.nudge(by: CGPoint(x: dx * Size.target, y: dy * Size.target), session.remote)
    }

    private func resize(_ handle: PanelHandle, _ dx: CGFloat, _ dy: CGFloat) {
        stage.resize(handle, by: CGPoint(x: dx * Size.target, y: dy * Size.target), session.remote)
    }
}

/// The header while arranging: start over, or finish.
struct RemoteEditHeader: View {
    let width: CGFloat

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(spacing: Space.s2) {
            Spacer(minLength: 0)
            HeaderButton(symbol: "arrow.counterclockwise", label: "Reset layout") {
                model.feedback.click()
                stage.resetLayout(session.remote)
            }
            .accessibilityIdentifier("remote.edit.reset")
            HeaderButton(symbol: "checkmark", label: "Done", look: .accent) {
                stage.editing = false
            }
            .accessibilityIdentifier("remote.edit.done")
            Spacer(minLength: 0)
        }
        .frame(width: width, height: RemoteMetrics.header)
    }
}

// MARK: Outlines and badges

/// The line around a module while arranging.
private struct Outline: View {
    let rect: CGRect

    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(theme.accentText, lineWidth: 1.5)
            .placed(rect)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The badge that hides a module: a 48 pt touch area around a 24 pt disc that sits in the module's corner.
private struct RemoveBadge: View {
    let module: RemoteModule
    let rect: CGRect
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: Space.s4, weight: .bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: Space.s6, height: Space.s6)
                .background(theme.accent, in: Circle())
                .frame(width: Size.target, height: Size.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: rect.maxX - 38, y: rect.minY - 10)
        .accessibilityLabel("Hide \(module.label)")
        .accessibilityIdentifier("remote.hide.\(module.rawValue)")
    }
}

// MARK: Tray

/// Along the panel's foot: the modules that are off, to put back, and any the panel is too small to hold (dimmed;
/// a tap drops them from the choice).
private struct ModuleTray: View {
    let hidden: [RemoteModule]
    let dropped: [RemoteModule]
    let rect: CGRect

    @Environment(AppSession.self) private var session

    var body: some View {
        let remote = session.remote
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(hidden, id: \.self) { module in
                    ModuleChip(label: module.label, dropped: false) {
                        remote.setModules(remote.modules.union([module]))
                    }
                }
                ForEach(dropped, id: \.self) { module in
                    ModuleChip(label: module.label, dropped: true) {
                        remote.setModules(remote.modules.subtracting([module]))
                    }
                }
            }
            .frame(height: rect.height)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}

private struct ModuleChip: View {
    let label: String
    let dropped: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                if !dropped {
                    Image(systemName: "plus")
                        .font(.system(size: Space.s4, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                }
                Text(label)
                    .textRole(.label)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.s3)
            .frame(height: Size.target)
            .background(theme.glassRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.edge, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(dropped ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dropped ? "Drop \(label)" : "Show \(label)")
    }
}

// MARK: Handles

/// A resize handle: the corner or edge's touch zone, with its mark. Corners are 48 pt squares and edges 32 pt bands
/// between them; the marks hug the panel's rounded corners and edges.
private struct ResizeHandle: View {
    let handle: PanelHandle
    let size: CGSize

    @Environment(\.theme) private var theme

    private static let corner: CGFloat = 48
    private static let edge: CGFloat = 32

    var body: some View {
        let zone = Self.zone(handle, in: size)
        HandleMark(handle: handle)
            .stroke(theme.accentText, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .frame(width: zone.width, height: zone.height)
            .contentShape(Rectangle())
            .resizesPanel(handle)
            .offset(x: zone.minX, y: zone.minY)
            .accessibilityHidden(true)
    }

    private static func zone(_ handle: PanelHandle, in size: CGSize) -> CGRect {
        if handle.isCorner {
            return CGRect(
                x: handle.left ? 0 : size.width - corner,
                y: handle.top ? 0 : size.height - corner,
                width: corner, height: corner
            )
        }
        if handle.top || handle.bottom {
            return CGRect(x: corner, y: handle.top ? 0 : size.height - edge, width: max(size.width - 2 * corner, 0), height: edge)
        }
        return CGRect(x: handle.left ? 0 : size.width - edge, y: corner, width: edge, height: max(size.height - 2 * corner, 0))
    }
}

private extension PanelHandle {
    var isCorner: Bool { (left || right) && (top || bottom) }
}

/// A handle's mark, drawn in its own zone: a quarter of the panel's rounded corner just inside it, or a short bar
/// along an edge.
private struct HandleMark: Shape {
    let handle: PanelHandle

    /// How far in from the panel's outline the marks sit.
    private static let inset: CGFloat = 6
    /// Half the length of an edge's bar.
    private static let arm: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if handle.isCorner {
            let corner = Radius.sheet
            let radius = corner - Self.inset
            let centre = CGPoint(x: handle.left ? corner : rect.width - corner, y: handle.top ? corner : rect.height - corner)
            // Degrees, with y down: the arc runs a quarter turn around the corner's centre.
            let start: CGFloat = switch (handle.left, handle.top) {
            case (true, true): 180
            case (false, true): 270
            case (false, false): 0
            case (true, false): 90
            }
            let steps = 12
            for step in 0...steps {
                let angle = (start + 90 * CGFloat(step) / CGFloat(steps)) * .pi / 180
                let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        } else if handle.top || handle.bottom {
            let y = handle.top ? Self.inset : rect.height - Self.inset
            path.move(to: CGPoint(x: rect.midX - Self.arm, y: y))
            path.addLine(to: CGPoint(x: rect.midX + Self.arm, y: y))
        } else {
            let x = handle.left ? Self.inset : rect.width - Self.inset
            path.move(to: CGPoint(x: x, y: rect.midY - Self.arm))
            path.addLine(to: CGPoint(x: x, y: rect.midY + Self.arm))
        }
        return path
    }
}
