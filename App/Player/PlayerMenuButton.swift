import SwiftUI
import UIKit

/// A player control that opens a native menu and keeps the controls up while it shows. The menu is
/// UIKit's own because a control is told each time its menu opens and closes; the rows of a SwiftUI
/// Menu are built once and kept, so their onAppear and onDisappear miss later opens and the closes.
/// The glyph is drawn like every other control's, and the UIKit button lies over it and takes the tap.
struct PlayerMenuButton: View {
    let model: PlayerModel
    let systemImage: String
    let label: String
    let identifier: String
    var order: UIContextMenuConfiguration.ElementOrder = .automatic
    /// Built in the caller's body, so the menu follows what it read from the model.
    let menu: UIMenu
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .modifier(PlayerControlFace(isPressed: isPressed))
            .accessibilityHidden(true)
            .overlay {
                MenuControl(model: model, label: label, identifier: identifier, order: order, menu: menu, isPressed: $isPressed)
            }
    }
}

private struct MenuControl: UIViewRepresentable {
    let model: PlayerModel
    let label: String
    let identifier: String
    let order: UIContextMenuConfiguration.ElementOrder
    let menu: UIMenu
    @Binding var isPressed: Bool

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton()
        button.showsMenuAsPrimaryAction = true
        return button
    }

    func updateUIView(_ button: MenuButton, context: Context) {
        button.preferredMenuElementOrder = order
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.isEnabled = context.environment.isEnabled
        button.opened = { [model] in model.menuOpened() }
        button.closed = { [model] in model.menuClosed() }
        button.pressed = { [binding = $isPressed] in binding.wrappedValue = $0 }
        button.show(menu)
    }

    /// The whole circle, whatever size an empty button asks for.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MenuButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleUIView(_ button: MenuButton, coordinator: Void) {
        button.leave()
    }
}

/// Reports its menu opening and closing, and being held down.
private final class MenuButton: UIButton {
    var opened: () -> Void = {}
    var closed: () -> Void = {}
    var pressed: (Bool) -> Void = { _ in }
    private var content: UIMenu?
    private var isOpen = false

    override var isHighlighted: Bool {
        didSet {
            if isHighlighted != oldValue { pressed(isHighlighted) }
        }
    }

    /// An open menu changes in place. The block runs once for each menu showing, the root and any open
    /// submenu, so each takes its counterpart by identifier. The same menu again is left alone: the press
    /// that opens the menu redraws the glyph, and that must not swap the menu about to show.
    func show(_ menu: UIMenu) {
        guard menu !== content else { return }
        content = menu
        if isOpen {
            contextMenuInteraction?.updateVisibleMenu { visible in menu.find(visible.identifier) ?? visible }
        } else {
            self.menu = menu
        }
    }

    /// Taken off screen with the menu up, when UIKit may not report the end.
    func leave() {
        guard isOpen else { return }
        contextMenuInteraction?.dismissMenu()
        setOpen(false)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        setOpen(true)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        setOpen(false)
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if open {
            opened()
        } else {
            // Changes that arrived while it showed, for the next opening.
            menu = content
            closed()
        }
    }
}

extension UIMenu {
    /// Rows set apart from their neighbours, under `title` when there is one.
    static func section(_ identifier: String, title: String = "", _ rows: [UIMenuElement]) -> UIMenu {
        UIMenu(title: title, identifier: Identifier(rawValue: identifier), options: .displayInline, children: rows)
    }

    /// A row that opens `rows`, with the current `value` under its title.
    static func submenu(_ identifier: String, title: String, systemImage: String? = nil, value: String, _ rows: [UIMenuElement]) -> UIMenu {
        let menu = UIMenu(
            title: title, subtitle: value, image: systemImage.flatMap { UIImage(systemName: $0) },
            identifier: Identifier(rawValue: identifier), children: rows
        )
        menu.accessibilityIdentifier = identifier
        return menu
    }

    /// This menu, or the one inside it, with `identifier`.
    fileprivate func find(_ identifier: Identifier) -> UIMenu? {
        if self.identifier == identifier { return self }
        for case let child as UIMenu in children {
            if let found = child.find(identifier) { return found }
        }
        return nil
    }
}

extension UIAction {
    /// A row with a checkmark while `isOn`.
    static func choice(
        _ title: String, detail: String? = nil, systemImage: String? = nil, isOn: Bool, isEnabled: Bool = true,
        pick: @escaping @MainActor () -> Void
    ) -> UIAction {
        UIAction(
            title: title, subtitle: detail, image: systemImage.flatMap { UIImage(systemName: $0) },
            attributes: isEnabled ? [] : .disabled, state: isOn ? .on : .off
        ) { _ in pick() }
    }

    /// A row that opens a sheet or a panel, with the current `value`, if it has one, under its title.
    static func row(
        _ title: String, systemImage: String, value: String? = nil, identifier: String? = nil, isEnabled: Bool = true,
        open: @escaping @MainActor () -> Void
    ) -> UIAction {
        let row = UIAction(
            title: title, subtitle: value, image: UIImage(systemName: systemImage), attributes: isEnabled ? [] : .disabled
        ) { _ in open() }
        row.accessibilityIdentifier = identifier
        return row
    }

    /// Words among the rows: a row that cannot be chosen.
    static func note(_ text: String) -> UIAction {
        UIAction(title: text, attributes: .disabled) { _ in }
    }
}
