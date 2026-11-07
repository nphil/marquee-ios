import MarqueeCore
import SwiftUI

extension EnvironmentValues {
    /// The chosen server's library, which resolves artwork paths. Nil before a server is chosen.
    @Entry var plexLibrary: PlexLibrary? = nil
}

/// Plex artwork or a web image at a fixed point size, requested at that size times the display scale.
/// A plain trackOff fill stands in until it arrives; with no image at all, the `placeholder` symbol shows
/// on it (DESIGN §11). Poster art is never tinted. Decorative: the view around it carries the label.
struct PlexArtView: View {
    let path: String?
    let size: CGSize
    var aspect: ContentMode = .fill
    var placeholder = "photo"

    @Environment(\.plexLibrary) private var library
    @Environment(\.displayScale) private var displayScale
    @Environment(\.theme) private var theme
    @State private var art: Art? = nil

    /// What arrived for one request; a nil image means it could not be loaded.
    private struct Art {
        let key: String
        let image: UIImage?
    }

    private var request: ArtRequest? {
        guard let path, !path.isEmpty, size.width > 0, size.height > 0 else { return nil }
        return ArtRequest(source: path, pointSize: size, scale: displayScale, server: library?.server.id)
    }

    var body: some View {
        let request = request
        let key = request?.cacheKey
        // Memory hits draw on the first frame, so scrolling back never flashes the fill.
        let current = art?.key == key ? art : nil
        let image = current?.image ?? request.flatMap { ImagePipeline.shared.cachedImage($0) }
        ZStack {
            theme.trackOff
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: aspect)
                    .transition(.opacity)
            } else if request == nil || (current != nil && current?.image == nil) {
                Image(systemName: placeholder)
                    .font(.system(size: min(40, max(12, min(size.width, size.height) * 0.28))))
                    .foregroundStyle(theme.ink3)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
        .task(id: request) {
            guard let request, ImagePipeline.shared.cachedImage(request) == nil else { return }
            let loaded = try? await ImagePipeline.shared.image(request, library: library)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                art = Art(key: request.cacheKey, image: loaded)
            }
        }
    }
}
