import Foundation

public enum PlexImageURL {
    /// A copy of a Plex image resized by the server to the pixels a view needs, via `/photo/:/transcode`.
    /// `path` is a Plex artwork path (`/library/metadata/12/thumb/1699`) or an absolute URL such as a cast
    /// photo. The URL carries no token: the image loader sends it as a header, and the URL doubles as the
    /// cache key.
    public static func transcoded(_ path: String, base: URL, width: Double, height: Double, scale: Double) -> URL? {
        guard !path.isEmpty, width > 0, height > 0, scale > 0 else { return nil }
        let query = [
            URLQueryItem(name: "width", value: String(pixels(width, scale))),
            URLQueryItem(name: "height", value: String(pixels(height, scale))),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
        ]
        return PlexURL.make(base: base, path: "/photo/:/transcode", query: query)
    }

    private static func pixels(_ points: Double, _ scale: Double) -> Int {
        Int((points * scale).rounded(.up))
    }
}
