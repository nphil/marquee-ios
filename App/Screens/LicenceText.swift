import Foundation

/// Licence files come wrapped at 70–80 columns for terminals, which wraps a second time on a phone
/// into ragged half-lines. Lines that ran to that margin are rejoined so the text wraps to the
/// screen; short lines, list items, `key: value` lines and column-aligned rows keep their breaks.
enum LicenceText {
    /// The paragraphs of `text` (blank-line separated), each keeping only its deliberate line breaks.
    static func paragraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [String] = []
        // Source lines that make up the displayed line being built.
        var run: [Substring] = []

        func endLine() {
            guard let first = run.first else { return }
            // Indents beyond four spaces centre headings for 80 columns; on a phone they only push text over.
            let indent = String(repeating: " ", count: min(first.prefix(while: \.isWhitespace).count, 4))
            let body = run.count == 1
                ? String(first.drop(while: \.isWhitespace))
                // Joined lines lose the spacing that justified them to the margin.
                : run.flatMap { $0.split(whereSeparator: \.isWhitespace) }.joined(separator: " ")
            lines.append(indent + body)
            run = []
        }
        func endParagraph() {
            endLine()
            if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
            lines = []
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) {
                endParagraph()
                continue
            }
            if let last = run.last, !continues(last, with: line) { endLine() }
            run.append(line)
        }
        endParagraph()
        return paragraphs
    }

    /// Whether `line` carries on the sentence of `previous`: `previous` ran to the margin, and `line`
    /// starts nothing of its own.
    private static func continues(_ previous: Substring, with line: Substring) -> Bool {
        let last = previous.trimmingCharacters(in: .whitespaces)
        let next = line.trimmingCharacters(in: .whitespaces)
        guard last.count >= margin, last.contains(" "), !last.hasSuffix(":"),
              !hasColumns(previous), !hasColumns(line)
        else { return false }
        let startsItem = #/^(?:[-*•o]|\d+[.)]|[A-Za-z]\)|\([A-Za-z0-9]{1,3}\)|#+)\s|^Copyright\b|^©|^[A-Za-z_][A-Za-z0-9_]*:\s/#
        return next.prefixMatch(of: startsItem) == nil
    }

    /// Lines at least this long (trimmed) reached the margin of a 64–80 column file.
    private static let margin = 56

    /// A run of four spaces inside the text aligns columns of a table.
    private static func hasColumns(_ line: Substring) -> Bool {
        line.drop(while: \.isWhitespace).contains("    ")
    }
}
