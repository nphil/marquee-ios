import MarqueeCore
import SwiftUI

/// A profile's initial in a circle on the raised fill.
struct AvatarView: View {
    let user: PlexHomeUser?
    let size: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let initial = user?.title.first {
                Text(String(initial).uppercased())
                    .font(.custom(Manrope.semiBold.rawValue, fixedSize: size * 0.42))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
            }
        }
        .foregroundStyle(theme.ink)
        .frame(width: size, height: size)
        .background(theme.glassRaised, in: Circle())
        .overlay(Circle().strokeBorder(theme.edgeRaised, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
