import SwiftUI

/// What is on the phone's screen, for the log and a report: the tab, the routes on each tab's stack and the
/// sheets and covers up.
@MainActor
enum DiagScreen {
    static var tab = "-"
    static var stacks: [String: [String]] = [:]
    private(set) static var sheets: [String] = []

    static var summary: String {
        let routes = stacks[tab].map { $0.isEmpty ? "root" : $0.joined(separator: " › ") } ?? "root"
        return "tab=\(tab) path=\(routes) sheets=\(sheets.isEmpty ? "-" : sheets.joined(separator: ","))"
    }

    static func presentation(_ name: String, shown: Bool) {
        if shown {
            sheets.append(name)
        } else if let index = sheets.lastIndex(of: name) {
            sheets.remove(at: index)
        }
        Diag.event(.nav, shown ? "present" : "dismiss", ["sheet": name, "open": sheets.count])
    }
}

extension View {
    /// Logs a sheet, cover or alert as it comes and goes, and keeps it on the report's screen line.
    func diagPresentation(_ name: String, isPresented: Bool) -> some View {
        onChange(of: isPresented) { _, shown in DiagScreen.presentation(name, shown: shown) }
    }

    /// Logs the text of an error or alert while it is on screen.
    func diagShown(_ text: String?, category: String) -> some View {
        onChange(of: text, initial: true) { _, text in
            guard let text, !text.isEmpty else { return }
            Diag.event(.ui, "shown", ["kind": category, "text": text], .notice)
        }
    }
}
