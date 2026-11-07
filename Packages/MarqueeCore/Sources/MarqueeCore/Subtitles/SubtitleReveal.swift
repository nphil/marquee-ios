import Foundation

/// When each word of a cue appears for Reveal as spoken. Without measured timing the times are an
/// estimate from the text alone: syllables and letters weigh each word, punctuation and line breaks
/// add pauses, and the last tenth of the cue is left as a tail with everything shown.
public enum SubtitleReveal {
    /// One word, by Character offset into the cue's text.
    public struct Word: Sendable, Equatable {
        public var offset: Int
        public var length: Int
        /// Seconds into the cue.
        public var start: TimeInterval

        public init(offset: Int, length: Int, start: TimeInterval) {
            self.offset = offset
            self.length = length
            self.start = start
        }
    }

    /// How long a word takes to fade in.
    public static let fade: TimeInterval = 0.12

    public static func estimate(_ text: String, duration: TimeInterval, by reveal: SubtitleLook.Reveal) -> [Word] {
        let words = tokens(text)
        guard reveal != .off, duration > 0, !words.isEmpty else { return [] }
        let span = duration * 0.9
        let total = words.reduce(0) { $0 + $1.weight + $1.pause }
        var elapsed = 0.0
        var timed: [Word] = []
        var lineStart: TimeInterval?
        for token in words {
            let start = total > 0 ? span * elapsed / total : 0
            if reveal == .line {
                // Every word of a line appears with the line's first.
                if lineStart == nil || token.startsLine { lineStart = start }
                timed.append(Word(offset: token.offset, length: token.length, start: lineStart ?? start))
            } else {
                timed.append(Word(offset: token.offset, length: token.length, start: start))
            }
            elapsed += token.weight + token.pause
        }
        return timed
    }

    /// How much of a word shows `elapsed` seconds into its cue, 0 to 1.
    public static func visibility(of word: Word, at elapsed: TimeInterval) -> Double {
        min(1, max(0, (elapsed - word.start) / fade))
    }

    private struct Token {
        var offset: Int
        var length: Int
        var weight: Double
        var pause: Double
        var startsLine: Bool
    }

    private static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current: (offset: Int, characters: [Character])?
        var newline = true
        func close() {
            guard let word = current else { return }
            current = nil
            tokens.append(Token(
                offset: word.offset, length: word.characters.count,
                weight: weight(word.characters), pause: pause(after: word.characters.last), startsLine: newline
            ))
            newline = false
        }
        for (offset, character) in text.enumerated() {
            if character.isNewline {
                close()
                if var last = tokens.popLast() {
                    last.pause = max(last.pause, 0.8)
                    tokens.append(last)
                }
                newline = true
            } else if character.isWhitespace {
                close()
            } else if isIdeograph(character) {
                // Scripts written without spaces reveal a character at a time.
                close()
                current = (offset, [character])
                close()
            } else if current == nil {
                current = (offset, [character])
            } else {
                current?.characters.append(character)
            }
        }
        close()
        return tokens
    }

    /// Syllables carry most of a word's length when spoken; letters add a little for long words.
    private static func weight(_ characters: [Character]) -> Double {
        let letters = characters.filter(\.isLetter)
        guard !letters.isEmpty else { return 0.2 }
        return Double(syllables(letters)) + 0.05 * Double(letters.count)
    }

    private static func syllables(_ letters: [Character]) -> Int {
        let lower = letters.map { Character($0.lowercased()) }
        guard lower.allSatisfy({ $0.isASCII }) else { return max(1, letters.count / 3) }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var previousVowel = false
        for letter in lower {
            let vowel = vowels.contains(letter)
            if vowel && !previousVowel { count += 1 }
            previousVowel = vowel
        }
        // A final silent e, as in "time", is not a syllable of its own; "table" keeps its "le".
        if count > 1, lower.last == "e", lower.count > 2, lower[lower.count - 2] != "l", !vowels.contains(lower[lower.count - 2]) {
            count -= 1
        }
        return max(1, count)
    }

    private static func pause(after last: Character?) -> Double {
        switch last {
        case ".", "!", "?", "…", "。", "！", "？": 1.0
        case ",", ";", ":", "—", "–", "、", "，": 0.5
        default: 0
        }
    }

    private static func isIdeograph(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }
}
