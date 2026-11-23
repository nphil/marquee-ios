import Foundation

/// Panel care for the floating orb: a bright button that sits in one place over content dims after a short dwell.
public enum OrbDimming {
    /// Seconds the orb may sit untouched before it dims.
    public static let dwell: TimeInterval = 4
    public static let dimmedOpacity: Double = 0.4

    /// True once the orb has sat untouched for `dwell` while it floats over content with the panel closed.
    public static func isDimmed(overContent: Bool, panelOpen: Bool, idle: TimeInterval) -> Bool {
        overContent && !panelOpen && idle >= dwell
    }
}
