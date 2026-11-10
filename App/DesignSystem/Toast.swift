import SwiftUI

/// Confirmations above the tab bar, one at a time (DESIGN §11, §12). A toast with Undo stays six
/// seconds, so Undo is reachable for at least five. A change that waits on a toast (`commit`) is sent
/// when the toast expires or another replaces it, and never once Undo is tapped.
@MainActor @Observable
final class ToastCenter {
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let undo: (@MainActor () -> Void)?
        let commit: (@MainActor () -> Void)?
    }

    private(set) var current: Toast?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func show(_ message: String, undo: (@MainActor () -> Void)? = nil, commit: (@MainActor () -> Void)? = nil) {
        finish()
        let toast = Toast(message: message, undo: undo, commit: commit)
        current = toast
        AccessibilityNotification.Announcement(message).post()
        let id = toast.id
        let seconds = undo == nil ? 3 : 6
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.current?.id == id else { return }
            self?.finish()
        }
    }

    func undo() {
        guard let toast = current else { return }
        expiry?.cancel()
        current = nil
        toast.undo?()
    }

    /// Ends the current toast and sends the change it held back. Called when the app leaves the
    /// foreground, so a change waiting out its toast is not lost with the app.
    func finish() {
        expiry?.cancel()
        expiry = nil
        guard let toast = current else { return }
        current = nil
        toast.commit?()
    }
}

/// The current toast, on an opaque sheet fill above the tab bar: 220 ms in with 8 pt of travel, 180 ms out,
/// and a plain 120 ms fade under Reduce Motion (DESIGN §9).
struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = center.current {
                ToastBar(toast: toast) { center.undo() }
                    .id(toast.id)
                    .transition(transition)
            }
        }
        .padding(.horizontal, Space.inset)
        .padding(.bottom, Space.s2)
    }

    private var transition: AnyTransition {
        if reduceMotion { return AnyTransition.opacity.animation(.linear(duration: 0.12)) }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: Space.s2)).animation(.easeOut(duration: 0.22)),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.18))
        )
    }
}

private struct ToastBar: View {
    let toast: ToastCenter.Toast
    let undo: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        HStack(spacing: Space.s3) {
            Text(toast.message)
                .textRole(.label)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Space.s3)
            if toast.undo != nil {
                Button(action: undo) {
                    Text("Undo")
                        .textRole(.headline)
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, Space.s3)
                        .frame(minWidth: Size.target, minHeight: Size.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, Space.s4)
        .padding(.trailing, toast.undo == nil ? Space.s4 : Space.s1)
        .frame(minHeight: Size.rowMin)
        .background(theme.roles.sheet.over(theme.roles.canvas).color, in: shape)
        .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}
