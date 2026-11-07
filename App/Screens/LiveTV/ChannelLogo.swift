import MarqueeCore
import SwiftUI
import UIKit

/// A channel's logo on a glass tile (docs/LIVE-TV.md §6.4). Without a logo, or while it loads, the call
/// sign stands in, so a row never shows an empty square.
struct ChannelLogo: View {
    let channel: LiveChannel
    var side: CGFloat = 40

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: UIImage?)?

    static func radius(side: CGFloat) -> CGFloat {
        side >= 40 ? Radius.inner(Radius.row, inset: Space.s2) : Radius.inner(Radius.control, inset: Space.s1)
    }

    var body: some View {
        let request = LogoImages.request(channel, side: side, scale: displayScale)
        let image = loaded?.key == request?.cacheKey ? loaded?.image : request.flatMap { ImagePipeline.shared.cachedImage($0) }
        let shape = RoundedRectangle(cornerRadius: Self.radius(side: side), style: .continuous)
        ZStack {
            shape.fill(theme.glass)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(side * LogoImages.inset)
            } else {
                Text(channel.callSign.isEmpty ? channel.number : channel.callSign)
                    .font(.system(size: side * 0.26, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.ink2)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            }
        }
        .frame(width: side, height: side)
        .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
        .accessibilityHidden(true)
        .task(id: request?.cacheKey) {
            guard let request, ImagePipeline.shared.cachedImage(request) == nil else { return }
            let image = try? await ImagePipeline.shared.image(request, library: nil)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { loaded = (request.cacheKey, image) }
        }
    }
}

/// Logo requests shared by the SwiftUI tile and the grid's UIKit cells.
enum LogoImages {
    /// The logo's margin inside its tile, as a share of the side.
    static let inset: CGFloat = 0.12

    static func request(_ channel: LiveChannel, side: CGFloat, scale: CGFloat) -> ArtRequest? {
        guard let logo = channel.logo, !logo.isEmpty else { return nil }
        let inner = side * (1 - 2 * inset)
        return ArtRequest(source: logo, pointSize: CGSize(width: inner, height: inner), scale: scale, server: nil)
    }
}
