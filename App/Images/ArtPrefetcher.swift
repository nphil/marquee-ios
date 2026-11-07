import MarqueeCore
import SwiftUI

/// Starts loading artwork that is about to scroll into view, at the size its `PlexArtView` will ask for, so
/// the cell finds it in memory on its first frame.
@MainActor
struct ArtPrefetcher: DynamicProperty {
    @Environment(\.plexLibrary) private var library
    @Environment(\.displayScale) private var displayScale

    func callAsFunction(_ paths: [String?], size: CGSize) {
        let server = library?.server.id
        let requests = paths.compactMap { path -> ArtRequest? in
            guard let path, !path.isEmpty else { return nil }
            return ArtRequest(source: path, pointSize: size, scale: displayScale, server: server)
        }
        guard !requests.isEmpty else { return }
        let library = library
        Task { await ImagePipeline.shared.prefetch(requests, library: library) }
    }
}
