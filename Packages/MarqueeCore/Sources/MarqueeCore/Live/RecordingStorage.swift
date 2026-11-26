import Foundation

/// How much the DVR's library holds, for the storage line on the Recordings screen. Plex reports the size of a
/// library and the hours in it, not the free space of the disk under it, so the line says what is used.
public struct RecordingStorage: Hashable, Sendable, Codable {
    public var usedBytes: Int64
    public var recordedSeconds: TimeInterval

    public init(usedBytes: Int64, recordedSeconds: TimeInterval) {
        self.usedBytes = usedBytes
        self.recordedSeconds = recordedSeconds
    }

    /// "Recordings use 41.2 GB, about 68 hours of video. Plex does not report free space, so how many hours are
    /// left cannot be shown."
    public var line: String {
        let hours = Int((recordedSeconds / 3_600).rounded())
        let video = hours > 0 ? ", about \(hours) \(hours == 1 ? "hour" : "hours") of video" : ""
        return "Recordings use \(Self.format(bytes: usedBytes))\(video). Plex does not report free space, so how many hours are left cannot be shown."
    }

    /// Decimal units, one decimal place: "41.2 GB", "1.3 TB".
    public static func format(bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        guard unit > 0 else { return "\(Int(value)) bytes" }
        let tenths = (value * 10).rounded() / 10
        return "\(tenths == tenths.rounded() ? String(Int(tenths)) : String(tenths)) \(units[unit])"
    }
}
