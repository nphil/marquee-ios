import MarqueeCore
import SwiftUI
import UIKit

/// Report a Problem (DESIGN §8.12): opens over whatever is on the phone's screen, from Diagnostic Logs, the
/// player's More menu or the floating button, and sends a note, a screenshot, the app's state and the whole
/// journal to the ntfy topic.
@MainActor @Observable
final class ReportCenter {
    static let shared = ReportCenter()

    enum Source: String {
        case settings, player, button, discovery
    }

    /// The active theme and scheme, for the sheet and the floating button, which hang outside RootView.
    var theme = ThemeCatalog.bundled.defaultDark
    var scheme: ColorScheme?
    /// The sheet's lists use `themedList`, whose scroll header reads the store from the environment; the
    /// sheet hangs outside RootView, so without it SwiftUI traps on opening (0.1.45).
    @ObservationIgnored var store: ThemeStore?
    private(set) var isOpen = false
    @ObservationIgnored weak var session: AppSession?
    @ObservationIgnored private weak var sheet: UIViewController?

    var isAvailable: Bool {
        session?.diagnostics.config != nil
    }

    /// Opens the sheet with `screenshot`, taken before whatever led here covered the screen.
    func open(from source: Source, screenshot: UIImage?) {
        guard !isOpen, let session, let store, session.diagnostics.config != nil, let top = Self.topController() else { return }
        Diag.event(.ui, "report.open", ["from": source.rawValue, "screenshot": screenshot != nil])
        let host = UIHostingController(rootView: ReportSheet(session: session, store: store, center: self, screenshot: screenshot, source: source))
        host.overrideUserInterfaceStyle = switch scheme {
        case .light: .light
        case .dark: .dark
        default: .unspecified
        }
        sheet = host
        isOpen = true
        top.present(host, animated: true)
    }

    func close() {
        sheet?.dismiss(animated: true)
    }

    fileprivate func closed() {
        isOpen = false
        sheet = nil
    }

    /// The phone's own scene's windows, bottom first, without the floating button's.
    private static func appWindows() -> [UIWindow] {
        guard let scene = GlassesCenter.phoneScene() else { return [] }
        return scene.windows.filter { !$0.isHidden && !($0 is ReportButtonWindow) }.sorted { $0.windowLevel < $1.windowLevel }
    }

    private static func topController() -> UIViewController? {
        let windows = appWindows()
        var top = (windows.first { $0.isKeyWindow } ?? windows.first { $0.windowLevel == .normal })?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// The phone's screen as it looks, without the floating button. Video draws black.
    static func capture() -> UIImage? {
        let windows = appWindows()
        guard let first = windows.first else { return nil }
        return UIGraphicsImageRenderer(bounds: first.bounds).image { _ in
            for window in windows { window.drawHierarchy(in: window.frame, afterScreenUpdates: false) }
        }
    }

    /// At most 1400 pixels on the long side, which keeps the interface readable at a fraction of the size.
    static func jpeg(_ image: UIImage) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 1400 / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.7, 0.5, 0.3] as [CGFloat] {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= 2_000_000 { return data }
        }
        return scaled.jpegData(compressionQuality: 0.2)
    }
}

/// The sheet in its own hosting controller, drawn in the app's theme.
private struct ReportSheet: View {
    let session: AppSession
    let store: ThemeStore
    let center: ReportCenter
    let screenshot: UIImage?
    let source: ReportCenter.Source

    var body: some View {
        ReportProblemView(screenshot: screenshot, source: source, close: center.close)
            .environment(session)
            .environment(store)
            .environment(\.theme, center.theme)
            .tint(center.theme.accentText)
            .onDisappear { center.closed() }
    }
}

struct ReportProblemView: View {
    let screenshot: UIImage?
    let source: ReportCenter.Source
    let close: @MainActor () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var note = ""
    @State private var includesScreenshot = true
    @State private var phase = Reporter.Phase.idle

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Note", text: $note, prompt: Text("What went wrong? (optional)").foregroundStyle(theme.ink3), axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("report.note")
                } footer: {
                    Text("A few words on what happened, and roughly when, help most.")
                        .foregroundStyle(theme.ink2)
                }
                .listRowBackground(theme.sheet)

                if let screenshot {
                    Section {
                        Toggle("Include Screenshot", isOn: $includesScreenshot)
                            .accessibilityIdentifier("report.includeScreenshot")
                        if includesScreenshot {
                            Image(uiImage: screenshot)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: Size.reportShot)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Screenshot of the screen")
                                .accessibilityIdentifier("report.screenshot")
                        }
                    } footer: {
                        Text("Video shows black in screenshots; the player's details go with the report instead.")
                            .foregroundStyle(theme.ink2)
                    }
                    .listRowBackground(theme.sheet)
                }

                Section {
                    Label("The log of the last day", systemImage: "doc.text")
                    Label("What is on screen and the player's details", systemImage: "rectangle.on.rectangle")
                    Label("Settings, without passwords or tokens", systemImage: "gearshape")
                } header: {
                    Text("Sent with the report")
                } footer: {
                    status
                        .accessibilityIdentifier("report.status")
                }
                .listRowBackground(theme.sheet)
            }
            .themedList(theme)
            .navigationTitle("Report a Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase.isSent ? "Done" : "Cancel", action: close)
                        .accessibilityIdentifier("report.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !phase.isSent {
                        Button("Send", action: send)
                            .disabled(phase == .sending)
                            .accessibilityIdentifier("report.send")
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase == .sending)
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            Text(destination)
                .foregroundStyle(theme.ink2)
        case .sending:
            Text("Sending…")
                .foregroundStyle(theme.ink2)
        case .sent(let id, let attached):
            StatusLine(
                symbol: "checkmark.circle.fill", tint: theme.positive,
                text: attached ? "Sent as report \(id), with the log attached." : "Sent as report \(id). The server takes no attachments, so the log's last part went as messages."
            )
        case .failed(let text):
            ProblemLine(text: text)
        }
    }

    private var destination: String {
        guard let config = session.diagnostics.config else { return "" }
        return "It goes to the topic \(config.topic) on \(config.server.host() ?? "the server"). Anyone who can read that topic can read the report."
    }

    private func send() {
        phase = .sending
        let shot = includesScreenshot ? screenshot : nil
        let note = note
        Task {
            phase = await Reporter.send(note: note, screenshot: shot, source: source, session: session)
        }
    }
}

/// Builds and sends a report: the journal with the app's state at its top as an attachment, the screenshot
/// as another, then a short message with the note that names both. A server that refuses attachments gets
/// the state and the journal's last 40 KB as messages instead.
@MainActor
enum Reporter {
    enum Phase: Equatable {
        case idle
        case sending
        case sent(id: String, attached: Bool)
        case failed(String)

        var isSent: Bool {
            if case .sent = self { true } else { false }
        }
    }

    private static let fallbackBytes = 40_000

    static func send(note: String, screenshot: UIImage?, source: ReportCenter.Source, session: AppSession) async -> Phase {
        let settings = session.diagnostics
        guard let config = settings.config else { return .failed("Diagnostic Logs is not set up.") }
        let id = "r" + String(UUID().uuidString.lowercased().prefix(4))
        let now = Date()
        let started = ContinuousClock.now
        let note = DiagRedactor.redact(note.trimmingCharacters(in: .whitespacesAndNewlines))
        Diag.event(.app, "report.send", ["report": id, "from": source.rawValue, "note": !note.isEmpty, "screenshot": screenshot != nil], .notice)
        let state = await ReportSnapshot.text(id: id, note: note, source: source, session: session)
        let journal = await DiagLog.shared.journalData()
        var body = Data(state.utf8)
        body.append(Data("\n\n==== Journal ====\n".utf8))
        body.append(journal)
        let device = settings.deviceName
        let logName = NtfyConfig.reportFilename(device: device, at: now)
        let title = settings.title

        let upload = await post(config.publish(NtfyMessage(
            title: title, text: "Report \(id): log", priority: .min,
            attachment: .init(data: body, filename: logName, contentType: "text/plain; charset=utf-8")
        )))
        let attached = upload.answer == .accepted
        if let problem = problem(upload, id: id) { return problem }
        if !attached {
            // Attachments are off on this server: the state and the journal's end as plain messages.
            let tail = String(decoding: journal.suffix(fallbackBytes), as: UTF8.self)
            let lines = (state + "\n==== Journal (last part) ====\n" + tail).split(separator: "\n").map { DiagLine(String($0)) }
            let parts = DiagPacker.pack(lines, limit: DiagPacker.messageLimit - 40)
            for (index, part) in parts.enumerated() {
                let outcome = await post(config.publish(NtfyMessage(
                    title: title, text: "Report \(id) part \(index + 1)/\(parts.count)\n" + part.text, priority: .min
                )))
                if let problem = problem(outcome, id: id) { return problem }
            }
        }
        var shotName: String?
        if attached, let screenshot, let jpeg = ReportCenter.jpeg(screenshot) {
            let name = NtfyConfig.reportFilename(device: device, at: now, ext: "jpg")
            let outcome = await post(config.publish(NtfyMessage(
                title: title, text: "Report \(id): screenshot", priority: .min,
                attachment: .init(data: jpeg, filename: name, contentType: "image/jpeg")
            )))
            if outcome.answer == .accepted { shotName = name }
        }
        var summary = ["Report \(id) from \(device)", note.isEmpty ? "No note." : "Note: \(note)", "Screen: \(DiagScreen.summary)"]
        summary.append(attached ? "Log: \(logName)" : "Log: in the messages before this one")
        if let shotName { summary.append("Screenshot: \(shotName)") }
        let outcome = await post(config.publish(NtfyMessage(
            title: "\(title) · Report", text: summary.joined(separator: "\n"), priority: .high, tags: ["memo"]
        )))
        if let problem = problem(outcome, id: id) { return problem }
        Diag.event(.app, "report.sent", ["report": id, "attached": attached, "bytes": body.count, "ms": Diag.ms(since: started)], .notice)
        return .sent(id: id, attached: attached)
    }

    private static func post(_ request: PlexRequest) async -> NtfyClient.Outcome {
        await NtfyClient.send(request, session: DiagLog.shared.session)
    }

    /// What to tell the person when a step failed; nil when it went, or only an attachment was refused.
    private static func problem(_ outcome: NtfyClient.Outcome, id: String) -> Phase? {
        let text: String
        switch outcome.answer {
        case .accepted, .attachmentRefused: return nil
        case .needsToken: text = "The server wants an access token, or does not know this one. Check it in Diagnostic Logs."
        case .refused: text = "The server refused to let this iPhone write to the topic. Check it in Diagnostic Logs."
        case .rateLimited: text = "The server is limiting how fast this iPhone sends. Try again in a minute."
        case .serverError(let status), .unexpected(let status): text = "The server answered with an error (\(status)). Try again later."
        case nil: text = "Can't reach the server. Check the address and that this iPhone is online."
        }
        Diag.event(.app, "report.failed", ["report": id, "status": outcome.status, "error": outcome.error], .warning)
        return .failed(text)
    }
}

/// The state a report carries above the journal: who sent it, the build and phone, what was on screen, the
/// player's own diagnostics and the settings, without secrets.
@MainActor
enum ReportSnapshot {
    static func text(id: String, note: String, source: ReportCenter.Source, session: AppSession) async -> String {
        var lines = [
            "Marquee report \(id) · \(Date().formatted(.iso8601))",
            "From: \(session.diagnostics.deviceName) · \(source.rawValue)",
            "Build: \(AppBuild.version) (\(AppBuild.build)) \(AppBuild.commit) · launch \(DiagLog.shared.launch)",
            "Phone: \(SystemMonitor.shared.summary)",
            "Network: \(SystemMonitor.shared.network)",
            "Note: \(note.isEmpty ? "-" : note)",
            "",
            "Screen: \(DiagScreen.summary)",
            "Server: \(session.server?.name ?? "-")",
            "Plugins: \(plugins(session))",
            "Diagnostic Logs: live \(session.diagnostics.sendsLive ? "on" : "off") · \(session.diagnostics.detailed ? "Detailed" : "Standard") · floating button \(session.diagnostics.showsButton ? "on" : "off")",
        ]
        if let model = session.player.active {
            let server = await PlayerStats.Server.read(model)
            lines += ["", "==== Player ====", PlayerStats.report(model, server: server)]
        }
        lines += ["", "==== Settings ====", Diag.describe(session.settings)]
        return lines.joined(separator: "\n")
    }

    private static func plugins(_ session: AppSession) -> String {
        let all: [(String, Bool)] = [
            ("Bazarr", session.bazarr.config != nil), ("Seerr", session.seerr.isEnabled),
            ("HomeLabber", session.homelabber.config != nil), ("SpeechDock", session.speechDock.origin != nil),
            ("Chromecast", session.cast.isEnabled), ("Remote", session.remote.isEnabled),
            ("Big Screen", session.glasses.isEnabled), ("Linked Phones", session.link.isEnabled),
        ]
        let on = all.filter(\.1).map(\.0)
        return on.isEmpty ? "none" : on.joined(separator: ", ")
    }
}
