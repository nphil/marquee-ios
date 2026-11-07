import MarqueeCore
import SwiftUI

/// A movie's or show's trailers, scenes and featurettes: 16:9 cards with the kind and length. Tapping one
/// plays it.
struct ExtrasShelf: View {
    let extras: [PlexMetadata]

    @Environment(\.theme) private var theme
    @Environment(\.sessionActions) private var session
    private static let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: "Extras")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(extras) { extra in
                        Button {
                            session.play(extra)
                        } label: {
                            card(extra)
                        }
                        .buttonStyle(.press)
                        .accessibilityHint("Plays it")
                    }
                }
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("detail.extras")
    }

    private func card(_ extra: PlexMetadata) -> some View {
        let height = (Self.width * 9 / 16).rounded()
        return VStack(alignment: .leading, spacing: Space.s1) {
            PlexArtView(path: extra.thumb, size: CGSize(width: Self.width, height: height), placeholder: "film")
                .frame(width: Self.width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .padding(.bottom, Space.s1)
            Text(extra.title)
                .textRole(.label)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Text([Self.kind(of: extra), ItemText.runtime(extra.duration)].compactMap(\.self).joined(separator: " · "))
                .textRole(.caption)
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func kind(of extra: PlexMetadata) -> String {
        switch extra.subtype {
        case "trailer": return "Trailer"
        case "deletedScene": return "Deleted Scene"
        case "interview": return "Interview"
        case "behindTheScenes": return "Behind the Scenes"
        case "sceneOrSample": return "Scene"
        case "featurette": return "Featurette"
        default: break
        }
        switch extra.extraType {
        case 1: return "Trailer"
        case 2: return "Deleted Scene"
        case 3: return "Interview"
        case 5: return "Behind the Scenes"
        case 6: return "Scene"
        default: return "Extra"
        }
    }

    /// The trailer Play Trailer starts: the one the server names first, else the first trailer listed.
    static func trailer(in extras: [PlexMetadata], primaryKey: String?) -> PlexMetadata? {
        if let primaryKey, let named = extras.first(where: { $0.key == primaryKey || primaryKey.hasSuffix("/\($0.ratingKey)") }) {
            return named
        }
        return extras.first { $0.subtype == "trailer" || $0.extraType == 1 }
    }
}
