import Foundation

/// Where a cue sits on the picture, numbered as the `{\anN}` tag of SubRip and ASS numbers it: 1 to 3 along
/// the bottom, 4 to 6 in the middle and 7 to 9 along the top, each left, centre and right.
public struct CueAlignment: Sendable, Hashable {
    public enum Vertical: Sendable, Hashable { case bottom, middle, top }
    public enum Horizontal: Sendable, Hashable { case left, centre, right }

    public var vertical: Vertical
    public var horizontal: Horizontal

    /// - Returns: nil unless `number` is 1 through 9.
    public init?(number: Int) {
        guard (1...9).contains(number) else { return nil }
        vertical = [Vertical.bottom, .middle, .top][(number - 1) / 3]
        horizontal = [Horizontal.left, .centre, .right][(number - 1) % 3]
    }
}

/// The `{\anN}` tag a SubRip cue may begin with, such as the signs and songs merged into a full subtitle
/// track, which ask for the top of the picture. The reader keeps a cue's first tag and then drops it, so
/// the place would be lost: each tag goes in as a marker the reader passes through as an ordinary
/// character, and comes out of the cue text with the place it named.
public enum CueMarkup {
    /// U+E000, a private-use character, in UTF-8.
    private static let marker: [UInt8] = [0xEE, 0x80, 0x80]
    private static let markerCharacter: Character = "\u{E000}"

    /// `srt` with each `{\anN}` (N from 1 to 9) replaced by the marker and N. Every other `{...}` is left
    /// for the reader to drop. Works on bytes, so a file in any ASCII-based encoding is handled alike.
    public static func marking(_ srt: Data) -> Data {
        let bytes = [UInt8](srt)
        var marked: [UInt8] = []
        marked.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            // "{\an", a digit and "}".
            if index + 5 < bytes.count, bytes[index] == 0x7B, bytes[index + 1] == 0x5C, bytes[index + 2] == 0x61,
               bytes[index + 3] == 0x6E, (0x31...0x39).contains(bytes[index + 4]), bytes[index + 5] == 0x7D {
                marked += marker
                marked.append(bytes[index + 4])
                index += 6
            } else {
                marked.append(bytes[index])
                index += 1
            }
        }
        return Data(marked)
    }

    /// Cue text as the reader returns it from a file `marking` prepared: the text without the markers, and
    /// the place the first of them named, nil when the cue named none.
    public static func placing(_ text: String) -> (text: String, alignment: CueAlignment?) {
        guard text.contains(markerCharacter) else { return (text, nil) }
        var plain = ""
        var alignment: CueAlignment?
        var rest = text[...]
        while let character = rest.first {
            rest = rest.dropFirst()
            guard character == markerCharacter else {
                plain.append(character)
                continue
            }
            if let digit = rest.first, digit.isASCII, let number = digit.wholeNumberValue {
                alignment = alignment ?? CueAlignment(number: number)
                rest = rest.dropFirst()
            }
        }
        return (plain, alignment)
    }
}
