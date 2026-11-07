import CryptoKit
import ImageIO
import MarqueeCore
import UIKit

/// One piece of artwork at the pixel size a view draws it: a Plex path, which the server resizes, or an
/// absolute URL (a watchlist poster, a profile photo), which is fetched as it is and resized here.
struct ArtRequest: Hashable, Sendable {
    let source: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// The server a Plex path belongs to, since paths repeat across servers. Empty for absolute URLs.
    let server: String
    /// Names the resized copy in memory and on disk. Independent of the server address and the token, so a
    /// copy survives both changing.
    let cacheKey: String

    init(source: String, pointSize: CGSize, scale: CGFloat, server: String?) {
        let absolute = Self.isAbsolute(source)
        self.source = absolute ? (URL(string: source)?.removingPlexToken.absoluteString ?? source) : source
        pixelWidth = max(1, Int((pointSize.width * scale).rounded(.up)))
        pixelHeight = max(1, Int((pointSize.height * scale).rounded(.up)))
        self.server = absolute ? "" : server ?? ""
        cacheKey = Self.keyPrefix(source: self.source, server: self.server) + "\(pixelWidth)x\(pixelHeight)"
    }

    /// The start of the cache key of every size of a Plex path's artwork.
    static func keyPrefix(source: String, server: String) -> String {
        hex(SHA256.hash(data: Data("\(server)|\(source)".utf8))) + "_"
    }

    var isAbsolute: Bool { Self.isAbsolute(source) }

    private static func isAbsolute(_ source: String) -> Bool {
        source.hasPrefix("https://") || source.hasPrefix("http://")
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Artwork in two tiers (adapted from Stashy's `ImageCache`): decoded bitmaps in memory and resized copies
/// on disk, so scrolling back and relaunching never refetch. Each image is decoded at the size it is
/// drawn and prepared for display here, off the main thread, so no cell decodes while scrolling.
actor ImagePipeline {
    static let shared = ImagePipeline()

    // NSCache is thread-safe, which makes the synchronous `cachedImage(_:)` peek from the main thread sound.
    nonisolated(unsafe) private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        // Cost is the decoded bitmap. 128 MB on a 6 GB phone, rising to 256 MB on 12 GB and up.
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        cache.totalCostLimit = min(256 * 1024 * 1024, max(128 * 1024 * 1024, physical / 48))
        return cache
    }()

    private let directory: URL
    private let session: URLSession
    private let maxDiskBytes = 800 * 1024 * 1024
    /// Disk use, counted once and then kept up to date on each write.
    private var diskBytes: Int?
    /// Loads under way by cache key. A cell asking twice and a prefetch share one download and decode.
    private var inFlight: [String: Task<UIImage, any Error>] = [:]

    private struct Prefetch: Sendable {
        let request: ArtRequest
        let library: PlexLibrary?
        let key: String
    }

    /// Small and bounded: during a fling, an unbounded queue would compete with the visible cells.
    private var prefetchQueue: [Prefetch] = []
    private var queuedKeys: Set<String> = []
    private var prefetchWorkers = 0
    private let maxPrefetchWorkers = 2
    private let maxQueuedPrefetches = 48

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appending(path: "Artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        // The resized copies are the cache; keeping the full responses as well would double the disk use.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        FakePlex.install(into: configuration)
        session = URLSession(configuration: configuration)
    }

    /// The image if it is decoded in memory. Never waits, so a cell can draw it on its first frame.
    nonisolated func cachedImage(_ request: ArtRequest) -> UIImage? {
        memory.object(forKey: request.cacheKey as NSString)
    }

    /// The image from memory, then disk, then the network. `library` resolves Plex paths.
    func image(_ request: ArtRequest, library: PlexLibrary?) async throws -> UIImage {
        let key = request.cacheKey
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return try await running.value }
        // Unstructured, so a cell that scrolls away and cancels its own task leaves the load running for
        // the others waiting on it.
        let task = Task { try await self.load(request, key: key, library: library) }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        return try await task.value
    }

    /// Loads images about to scroll into view, nearest first, two at a time.
    func prefetch(_ requests: [ArtRequest], library: PlexLibrary?) {
        // Workers take from the end, so the first request is appended last.
        for request in requests.reversed() {
            let key = request.cacheKey
            guard memory.object(forKey: key as NSString) == nil, inFlight[key] == nil, !queuedKeys.contains(key),
                  !FileManager.default.fileExists(atPath: location(of: key).path(percentEncoded: false))
            else { continue }
            if prefetchQueue.count >= maxQueuedPrefetches {
                queuedKeys.remove(prefetchQueue.removeFirst().key)
            }
            prefetchQueue.append(Prefetch(request: request, library: library, key: key))
            queuedKeys.insert(key)
        }
        while prefetchWorkers < maxPrefetchWorkers, !prefetchQueue.isEmpty {
            prefetchWorkers += 1
            Task(priority: .background) { await self.drainPrefetches() }
        }
    }

    private func drainPrefetches() async {
        while let next = prefetchQueue.popLast() {
            queuedKeys.remove(next.key)
            _ = try? await image(next.request, library: next.library)
        }
        prefetchWorkers -= 1
    }

    /// Delete All Local Data: every decoded bitmap and stored copy. Returns false when a file stayed.
    func removeAll() -> Bool {
        memory.removeAllObjects()
        prefetchQueue.removeAll()
        queuedKeys.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removedAll = true
        for file in files where (try? FileManager.default.removeItem(at: file)) == nil {
            removedAll = false
        }
        diskBytes = nil
        return removedAll
    }

    /// Drops every size of these Plex paths' artwork from memory and disk: a deleted title's.
    func forget(_ sources: [String], server: String) {
        let prefixes = sources.map { ArtRequest.keyPrefix(source: $0, server: server) }
        guard !prefixes.isEmpty else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where prefixes.contains(where: file.lastPathComponent.hasPrefix) {
            memory.removeObject(forKey: file.lastPathComponent as NSString)
            try? FileManager.default.removeItem(at: file)
        }
        diskBytes = nil
    }

    private func load(_ request: ArtRequest, key: String, library: PlexLibrary?) async throws -> UIImage {
        let file = location(of: key)
        if let stored = await ArtCoding.stored(at: file) {
            remember(stored, key: key)
            return stored
        }
        let data = try await download(request, library: library)
        let target = CGSize(width: request.pixelWidth, height: request.pixelHeight)
        let (image, encoded) = try await ArtCoding.decode(data, toFill: target)
        remember(image, key: key)
        if let encoded, await ArtCoding.write(encoded, to: file) { account(encoded.count) }
        return image
    }

    private func download(_ request: ArtRequest, library: PlexLibrary?) async throws -> Data {
        var urlRequest: URLRequest
        if request.isAbsolute {
            // Fetched without the server token: these hosts are not the server.
            guard let url = URL(string: request.source) else { throw URLError(.badURL) }
            urlRequest = URLRequest(url: url)
        } else {
            guard let library,
                  let url = try await library.imageURL(
                      request.source,
                      width: Double(request.pixelWidth),
                      height: Double(request.pixelHeight),
                      scale: 1
                  )
            else { throw URLError(.badURL) }
            urlRequest = URLRequest(url: url)
            for (name, value) in library.authorizationHeaders() {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func remember(_ image: UIImage, key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func location(of key: String) -> URL {
        directory.appending(path: key, directoryHint: .notDirectory)
    }

    private func account(_ bytes: Int) {
        let total = (diskBytes ?? measuredDiskBytes()) + bytes
        diskBytes = total
        if total > maxDiskBytes { evictOldest() }
    }

    private func measuredDiskBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Removes the least recently used copies down to 85% of the cap, so the next write does not scan
    /// the folder again. The total is recounted from the listing first: two loads of one key overwrite one
    /// file but count it twice.
    private func evictOldest() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.map { file in
            let values = try? file.resourceValues(forKeys: keys)
            return (url: file, size: values?.fileSize ?? 0, date: values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        if total > maxDiskBytes {
            entries.sort { $0.date < $1.date }
            let lowWater = maxDiskBytes * 85 / 100
            for entry in entries where total > lowWater {
                try? FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            }
        }
        diskBytes = total
    }
}

/// File and bitmap work, run on the concurrent pool rather than the pipeline's actor so loads never queue
/// behind one another's decoding or disk access.
private enum ArtCoding {
    /// A stored copy, decoded and prepared for display.
    @concurrent
    static func stored(at file: URL) async -> UIImage? {
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        // Eviction goes by modification date, least recently used first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path(percentEncoded: false))
        return await image.byPreparingForDisplay() ?? image
    }

    /// A download decoded at the size it is drawn and prepared for display, with the copy to store.
    @concurrent
    static func decode(_ data: Data, toFill target: CGSize) async throws -> (image: UIImage, encoded: Data?) {
        guard let decoded = downsample(data, toFill: target) else { throw URLError(.cannotDecodeContentData) }
        let encoded = encode(decoded)
        return (await decoded.byPreparingForDisplay() ?? decoded, encoded)
    }

    @concurrent
    static func write(_ data: Data, to file: URL) async -> Bool {
        (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Decodes straight to the smallest size that still fills `target`, never above the original, without
    /// holding the full-size bitmap.
    private static func downsample(_ data: Data, toFill target: CGSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var maxPixel = max(target.width, target.height)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            let scale = min(1, max(target.width / width, target.height / height))
            maxPixel = (max(width, height) * scale).rounded(.up)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// JPEG for opaque art; PNG keeps the transparency of logos and profile pictures.
    private static func encode(_ image: UIImage) -> Data? {
        guard let alpha = image.cgImage?.alphaInfo else { return image.pngData() }
        switch alpha {
        case .none, .noneSkipFirst, .noneSkipLast: return image.jpegData(compressionQuality: 0.7)
        default: return image.pngData()
        }
    }
}
