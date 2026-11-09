import AVFoundation
import CoreMedia
import MarqueeCore
import SwiftUI

/// The text AVPlayer reads from the stream: an MP4 text track, captions carried in the video, or the remux's
/// WebVTT. Marquee takes it from the player to draw it in the profile's look and timing; AVPlayer draws it
/// only where Marquee's overlay is not seen, in Picture in Picture and on an AirPlay screen.
@MainActor
final class StreamText: NSObject {
    /// The text from `start`, in the item's time, until the next change; nil is a gap.
    private struct Change {
        var start: TimeInterval
        var text: AttributedString?
    }

    private var output: AVPlayerItemLegibleOutput?
    private var changes: [Change] = []

    /// AVPlayer draws the text itself.
    var playerDraws = false {
        didSet { output?.suppressesPlayerRendering = !playerDraws }
    }

    /// Takes the text of a new item; what the last one showed is forgotten.
    func attach(to item: AVPlayerItem) {
        let output = AVPlayerItemLegibleOutput()
        // The user's system caption style is the look's job here.
        output.textStylingResolution = .sourceAndRulesOnly
        output.suppressesPlayerRendering = !playerDraws
        output.setDelegate(self, queue: .main)
        item.add(output)
        self.output = output
        changes = []
    }

    /// A line from before a seek must not run on after it.
    func reset() {
        changes = []
    }

    /// The line showing at `itemTime` and when it started; its end too once the next change is known.
    func line(at itemTime: TimeInterval) -> (text: AttributedString, start: TimeInterval, end: TimeInterval?)? {
        guard let index = changes.lastIndex(where: { $0.start <= itemTime }), let text = changes[index].text else { return nil }
        let next = index + 1
        return (text, changes[index].start, next < changes.count ? changes[next].start : nil)
    }
}

extension StreamText: @preconcurrency AVPlayerItemLegibleOutputPushDelegate {
    func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        let start = itemTime.seconds
        guard output === self.output, start.isFinite else { return }
        // A change at or before one already held means the player went back.
        changes.removeAll { $0.start >= start }
        // A delay of up to the timing limit still finds the line it holds back.
        if let first = changes.lastIndex(where: { $0.start < start - SubtitleTiming.limit }) {
            changes.removeFirst(first)
        }
        changes.append(Change(start: start, text: CaptionMarkup.attributed(strings)))
    }

    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        guard output === self.output else { return }
        changes = []
    }
}

/// The text and the source's own styling from the strings a legible output gives: italics, bold, underline
/// and colour. Padding spaces, which captions use to place a line, go.
@MainActor
enum CaptionMarkup {
    static func attributed(_ strings: [NSAttributedString]) -> AttributedString? {
        var lines: [AttributedString] = []
        // The output hands over every cue showing, and a stream may carry one cue twice (a cue that spans
        // two segments is written into both), so a string with the lines of an earlier one is dropped.
        var seen: Set<[String]> = []
        for string in strings {
            let block = SubtitleLine.lines(attributed(string)).map(trimmed).filter { !$0.characters.isEmpty }
            if seen.insert(block.map { String($0.characters) }).inserted { lines += block }
        }
        guard var text = lines.first else { return nil }
        for line in lines.dropFirst() {
            text += AttributedString("\n")
            text += line
        }
        return text
    }

    private static func attributed(_ string: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length), options: []) { attributes, range, _ in
            var run = AttributedString(string.attributedSubstring(from: range).string)
            var intent: InlinePresentationIntent = []
            if flag(attributes, kCMTextMarkupAttribute_ItalicStyle) { intent.insert(.emphasized) }
            if flag(attributes, kCMTextMarkupAttribute_BoldStyle) { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if flag(attributes, kCMTextMarkupAttribute_UnderlineStyle) { run.underlineStyle = .single }
            if let colour = colour(attributes[NSAttributedString.Key(kCMTextMarkupAttribute_ForegroundColorARGB as String)]) {
                run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = colour
            }
            result += run
        }
        return result
    }

    private static func flag(_ attributes: [NSAttributedString.Key: Any], _ key: CFString) -> Bool {
        (attributes[NSAttributedString.Key(key as String)] as? NSNumber)?.boolValue ?? false
    }

    /// White is every caption format's default, so only another colour is the file's own.
    private static func colour(_ value: Any?) -> Color? {
        guard let argb = (value as? [NSNumber])?.map(\.doubleValue), argb.count == 4 else { return nil }
        let (red, green, blue) = (argb[1], argb[2], argb[3])
        guard min(red, green, blue) < 0.95 else { return nil }
        return Color(red: red, green: green, blue: blue)
    }

    private static func trimmed(_ line: AttributedString) -> AttributedString {
        let characters = line.characters
        var start = characters.startIndex
        var end = characters.endIndex
        while start < end, characters[start].isWhitespace { start = characters.index(after: start) }
        while end > start, characters[characters.index(before: end)].isWhitespace { end = characters.index(before: end) }
        return AttributedString(line[start..<end])
    }
}
