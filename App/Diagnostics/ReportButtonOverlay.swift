import SwiftUI
import UIKit

/// The floating report button (DESIGN §8.12), opt-in under Diagnostic Logs: a round button in a window of
/// its own above everything on the phone, video included, that drags out of the way. A tap takes the screen
/// as it is, without the button, and opens Report a Problem. Only on the phone's scene, never on the
/// glasses' or a TV's.
@MainActor
final class ReportButton {
    static let shared = ReportButton()
    private var window: ReportButtonWindow?
    private var enabled = false

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { install() } else { remove() }
    }

    /// The phone's scene comes up after the settings are read at launch.
    func sceneReady() {
        if enabled { install() }
    }

    private func install() {
        guard window == nil, let scene = GlassesCenter.phoneScene() else { return }
        let window = ReportButtonWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear
        window.rootViewController = ReportButtonController()
        // Shown without becoming key, so the app's window keeps the keyboard and focus.
        window.isHidden = false
        self.window = window
        Diag.event(.ui, "report.button", ["shown": true])
    }

    private func remove() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        Diag.event(.ui, "report.button", ["shown": false])
    }
}

/// Passes every touch through except those on the button, and all of them while the report is open.
final class ReportButtonWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !ReportCenter.shared.isOpen else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view ? nil : hit
    }
}

private final class ReportButtonController: UIViewController {
    private var face: UIView?
    private var placed = false

    /// The player's own answer, so this window never vetoes a turn the player asked for.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { PlayerOrientation.allowed }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ReportButtonFace { [weak self] in self?.tapped() })
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        host.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        face = host.view
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let face else { return }
        face.bounds.size = CGSize(width: Size.target, height: Size.target)
        if !placed {
            placed = true
            // At rest on the trailing edge, above the tab bar.
            let area = view.bounds.inset(by: view.safeAreaInsets)
            face.center = CGPoint(x: area.maxX - Space.s4 - Size.target / 2, y: area.maxY - Size.rowMin - Size.target)
        }
        // Rotation and a new safe area keep it on screen.
        face.center = clamped(face.center)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let area = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: Size.target / 2, dy: Size.target / 2)
        guard !area.isNull, area.width >= 0, area.height >= 0 else { return point }
        return CGPoint(x: min(max(point.x, area.minX), area.maxX), y: min(max(point.y, area.minY), area.maxY))
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let face = gesture.view else { return }
        let move = gesture.translation(in: view)
        face.center = clamped(CGPoint(x: face.center.x + move.x, y: face.center.y + move.y))
        gesture.setTranslation(.zero, in: view)
    }

    private func tapped() {
        Diag.tap("report.floating")
        ReportCenter.shared.open(from: .button, screenshot: ReportCenter.capture())
    }
}

/// The button itself, in the active theme's raised glass.
private struct ReportButtonFace: View {
    let tap: @MainActor () -> Void

    var body: some View {
        let center = ReportCenter.shared
        Button(action: tap) {
            Image(systemName: "exclamationmark.bubble")
        }
        .buttonStyle(.round)
        .environment(\.theme, center.theme)
        .opacity(center.isOpen ? 0 : 1)
        .accessibilityLabel("Report a Problem")
        .accessibilityIdentifier("report.floating")
    }
}
