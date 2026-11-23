/// How the pad's thumb area behaves. The raw value is the saved id.
public enum RemotePadMode: String, CaseIterable, Sendable {
    case dpad, joystick, touchpad

    /// Anything unknown, or nothing saved, is the D-pad.
    public init(decoding id: String?) {
        self = id.flatMap(Self.init(rawValue:)) ?? .dpad
    }
}
