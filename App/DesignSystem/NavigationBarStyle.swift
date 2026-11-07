import SwiftUI
import UIKit

/// Title colour and the Manrope large title for the system navigation bars. Only the text is
/// styled: the bars keep their own Liquid Glass background (an opaque themed bar loses the
/// scroll-under-glass look, DESIGN §5.2).
@MainActor
enum NavigationBarStyle {
    static func apply(_ theme: Theme, typeSize: DynamicTypeSize, boldText: Bool) {
        let ink = theme.roles.ink.uiColor
        let cut: Manrope = boldText ? Manrope.medium.bolder : .medium
        let size = Manrope.size(34, as: .largeTitle, at: typeSize, cap: .accessibility3)
        let largeFont = UIFont(name: cut.rawValue, size: size) ?? .preferredFont(forTextStyle: .largeTitle)
        let large: [NSAttributedString.Key: Any] = [
            .foregroundColor: ink,
            .font: largeFont,
            .kern: -0.02 * size,
        ]
        let inline: [NSAttributedString.Key: Any] = [.foregroundColor: ink]

        let proxy = UINavigationBar.appearance()
        proxy.largeTitleTextAttributes = large
        proxy.titleTextAttributes = inline
        // The appearance proxy only reaches bars created from now on; restyle the live ones so a
        // theme change never leaves a bar in the old colour.
        for bar in liveBars() {
            bar.largeTitleTextAttributes = large
            bar.titleTextAttributes = inline
        }
    }

    private static func liveBars() -> [UINavigationBar] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .compactMap { $0.rootViewController }
            .flatMap { navigationControllers(in: $0) }
            .map { $0.navigationBar }
    }

    private static func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        var found = (controller as? UINavigationController).map { [$0] } ?? []
        for child in controller.children {
            found += navigationControllers(in: child)
        }
        if let presented = controller.presentedViewController, presented.presentingViewController === controller {
            found += navigationControllers(in: presented)
        }
        return found
    }
}
