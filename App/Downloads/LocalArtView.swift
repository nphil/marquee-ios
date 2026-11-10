import ImageIO
import SwiftUI
import UIKit

/// A download's artwork read from its folder on the iPhone, so it draws without a connection. Looks as
/// `PlexArtView` does: the trackOff fill until it arrives, the `placeholder` symbol where the file is
/// missing. Decorative: the row around it carries the label.
struct LocalArtView: View {
    let file: URL
    let size: CGSize
    var placeholder = "photo"

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @Environment(\.theme) private var theme
    @State private var art: Art? = nil

    /// What was read for one file; a nil image means it could not be.
    private struct Art {
        let key: String
        let image: UIImage?
    }

    /// The file at the pixel size it is drawn. `version` counts up when a still is saved after the row
    /// first drew, so a missing file is read again once it exists.
    private struct Load: Equatable {
        let file: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let version: Int

        var key: String { "\(file.path(percentEncoded: false))|\(pixelWidth)x\(pixelHeight)" }
    }

    private var load: Load {
        Load(
            file: file,
            pixelWidth: max(1, Int((size.width * displayScale).rounded(.up))),
            pixelHeight: max(1, Int((size.height * displayScale).rounded(.up))),
            version: session.downloads.artVersion
        )
    }

    var body: some View {
        let load = load
        let key = load.key
        // Memory hits draw on the first frame, so scrolling back never flashes the fill.
        let current = art?.key == key ? art : nil
        let image = current?.image ?? LocalArtCache.image(for: key)
        ZStack {
            theme.trackOff
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if current != nil {
                Image(systemName: placeholder)
                    .font(.system(size: min(40, max(12, min(size.width, size.height) * 0.28))))
                    .foregroundStyle(theme.ink3)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
        .task(id: load) {
            var loaded = LocalArtCache.image(for: key)
            if loaded == nil {
                loaded = await LocalArtLoader.read(load.file, pixelWidth: load.pixelWidth, pixelHeight: load.pixelHeight)
                guard !Task.isCancelled else { return }
                if let loaded { LocalArtCache.store(loaded, for: key) }
            }
            withAnimation(.easeOut(duration: 0.12)) {
                art = Art(key: key, image: loaded)
            }
        }
    }
}

/// Decoded artwork by file and size. A few dozen small bitmaps, dropped under memory pressure.
private enum LocalArtCache {
    // NSCache is thread-safe, which is what makes reading it from a view body sound.
    nonisolated(unsafe) private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        images.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private enum LocalArtLoader {
    /// Decodes straight to the smallest size that still fills the frame, never above the original, off the
    /// main thread and ready to draw.
    @concurrent
    static func read(_ file: URL, pixelWidth: Int, pixelHeight: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var longest = Double(max(pixelWidth, pixelHeight))
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            let scale = min(1, max(Double(pixelWidth) / width, Double(pixelHeight) / height))
            longest = (max(width, height) * scale).rounded(.up)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let decoded = UIImage(cgImage: image)
        return await decoded.byPreparingForDisplay() ?? decoded
    }
}
