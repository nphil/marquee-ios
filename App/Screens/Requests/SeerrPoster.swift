import MarqueeCore
import SwiftUI

/// A title's poster that opens its Seerr page. One title can sit in several shelves at once, so UI tests
/// take the first poster with an identifier.
struct SeerrTitleButton: View {
    let title: SeerrTitle
    let width: CGFloat

    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Button { openRoute(.seerrTitle(title)) } label: {
            SeerrPoster(title: title, width: width)
        }
        .buttonStyle(.press)
        .accessibilityIdentifier("seerr.poster.\(title.id)")
    }
}

/// 2:3 art with the title's status on it, then its name and year, or what Seerr says of its status.
struct SeerrPoster: View {
    let title: SeerrTitle
    let width: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            PlexArtView(path: TMDBImage.url(title.posterPath, pixels: width * scale)?.absoluteString, size: PosterCell.artSize(width: width))
                .overlay(alignment: .topTrailing) {
                    if let badge = title.badge {
                        Image(systemName: symbol(badge))
                            .textRole(.caption)
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, Space.s2)
                            .padding(.vertical, Space.s1 / 2)
                            .background(theme.canvas, in: Capsule())
                            .padding(Space.s2)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: width >= 96 ? Radius.tile : Radius.control, style: .continuous))
            Text(title.name).textRole(.caption).fontWeight(.semibold).foregroundStyle(theme.ink).lineLimit(1)
            Text(title.badge?.title ?? title.year.map(String.init) ?? " ")
                .textRole(.caption).foregroundStyle(theme.ink2).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.name)
        .accessibilityValue(title.badge?.title ?? title.year.map(String.init) ?? "")
    }

    private func symbol(_ badge: SeerrBadge) -> String {
        switch badge {
        case .available: "checkmark"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .processing: "arrow.down"
        case .approved: "clock"
        case .pending: "hourglass"
        case .declined: "xmark"
        case .failed: "exclamationmark.triangle"
        case .blocklisted: "nosign"
        }
    }
}

extension SeerrView {
    /// The line under a Seerr failure on Requests and the browse screen.
    static func message(for error: any Error) -> String {
        guard let error = error as? SeerrError else { return "Couldn't reach Seerr. Try again." }
        return text(for: error)
    }
}
