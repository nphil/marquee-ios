import Foundation

/// Which of HomeLabber's two scorings judges a screen. HomeLabber scores every title twice: its standard
/// VMAF model for a large screen and its phone model for a phone's size and distance, which rates the same
/// picture higher. A download or a stream on a phone is judged by the phone model, on a tablet by the standard.
///
/// The class is the device's, not the window's: a tablet in a narrow split window is still a tablet.
public enum ScreenClass: String, Sendable, Hashable, Codable {
    case phone
    case tablet
}

/// HomeLabber's word on one title (`HomeLabberClient.answer`).
public enum QualityMapAnswer: Sendable, Hashable {
    /// The title is measured.
    case scored(QualityMapEntry)
    /// The file is smaller than the smallest conversion HomeLabber can measure, so every quality is the original.
    /// `sourceKbps` is HomeLabber's bitrate for it, and `mediaID` the version, when HomeLabber says which.
    case useOriginal(sourceKbps: Int?, mediaID: String?)
    /// Not measured yet, or no word from HomeLabber.
    case unscored

    /// This answer for `media`, or `.unscored` when it is not about that version: a title plays and downloads from
    /// whichever version is asked for, and HomeLabber measures one (`QualityMapEntry.mediaID`), so another version
    /// or a replaced file is not covered. The `useOriginal` answer names no version, so it must agree with the
    /// bitrate Plex lists for this one, to a quarter or 150 kbit/s either way: a 40 Mbit/s second version of a
    /// title whose 1 Mbit/s first version is too small to convert is not the original to take.
    public func verified(for media: PlexMedia) -> QualityMapAnswer {
        switch self {
        case .scored(let entry):
            return entry.mediaID == String(media.id) ? self : .unscored
        case .useOriginal(let sourceKbps, let mediaID):
            if let mediaID { return mediaID == String(media.id) ? self : .unscored }
            guard let sourceKbps, Self.listed(media).contains(where: { abs($0 - sourceKbps) <= max(150, $0 / 4) }) else {
                return .unscored
            }
            return self
        case .unscored:
            return self
        }
    }

    /// The curve Auto streams `media` by on `screen`; nil unless HomeLabber measured this version.
    public func curve(for media: PlexMedia, screen: ScreenClass) -> QualityCurve? {
        guard case .scored(let entry) = verified(for: media) else { return nil }
        let curve = QualityCurve(entry.curve(for: screen))
        return curve.isEmpty ? nil : curve
    }

    /// The bitrates Plex lists for a version: the file's, and its video's alone.
    private static func listed(_ media: PlexMedia) -> [Int] {
        [media.bitrate, media.parts.first?.videoStream?.bitrate].compactMap { $0 }.filter { $0 > 0 }
    }
}

extension QualityMapEntry {
    /// The tiers to choose from on `screen`. A phone takes the phone model's tiers where HomeLabber has them, tier by
    /// tier, else the standard ones; a tablet always takes the standard ones.
    public func tiers(for screen: ScreenClass) -> [DownloadTier: Point] {
        guard screen == .phone, let phoneTiers else { return tiers }
        return tiers.merging(phoneTiers) { _, phone in phone }
    }

    /// The curve as `screen` judges it, each point's `vmaf` being that screen's score. A phone gets the phone
    /// model's scores only when every point has one: the two models' scores are not on one scale, so a curve of
    /// both would bend.
    public func curve(for screen: ScreenClass) -> [Point] {
        guard screen == .phone, !curve.isEmpty else { return curve }
        let phone = curve.compactMap { point in
            point.vmafPhone.map { Point(kbps: point.kbps, vmaf: $0, height: point.height) }
        }
        return phone.count == curve.count ? phone : curve
    }
}
