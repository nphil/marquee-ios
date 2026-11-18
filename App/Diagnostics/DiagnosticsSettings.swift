import MarqueeCore
import SwiftUI

/// Diagnostic Logs (DESIGN §8.12): the ntfy topic the log goes to, the name its messages carry, whether it
/// is sent live, how much is kept and whether the floating report button shows, and the last connection
/// test. Per iPhone: they stay through sign-out and profile switches.
@MainActor @Observable
final class DiagnosticsSettings {
    enum Check: Equatable {
        case untested
        case testing
        case sent
        /// A 401: the server wants a token, or does not know this one.
        case needsToken
        /// A 403: the token may not write to the topic.
        case refused
        case unreachable
        case failed(Int)
    }

    private(set) var config: NtfyConfig?
    /// The name typed for this iPhone; empty uses `defaultName`.
    private(set) var name: String
    private(set) var sendsLive: Bool
    private(set) var detailed: Bool
    private(set) var showsButton: Bool
    private(set) var check = Check.untested
    /// The live sender as it last reported.
    private(set) var live = NtfySender.State.off
    /// The signed-in profile, for the default name.
    var profileName: String? {
        didSet { if profileName != oldValue { apply() } }
    }
    @ObservationIgnored private let storage: SessionStorage
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(storage: SessionStorage) {
        self.storage = storage
        config = storage.ntfy
        name = storage.diagName
        sendsLive = storage.diagLive
        detailed = storage.diagDetailed
        showsButton = storage.diagButton
        DiagLog.shared.observeSender { [weak self] state in
            Task { @MainActor in self?.live = state }
        }
        apply()
        Diag.event(.integration, "diagnostics", [
            "setUp": config != nil, "server": config?.server.host(), "auth": config?.token != nil, "live": sendsLive,
            "detailed": detailed, "button": showsButton,
        ])
    }

    var defaultName: String {
        profileName.map { "\($0)’s iPhone" } ?? "iPhone"
    }

    var deviceName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? defaultName : typed
    }

    /// `Marquee 0.1.45 · Isabel’s iPhone`: the title of every message from this iPhone.
    var title: String {
        "Marquee \(AppBuild.version) · \(deviceName)"
    }

    func save(_ config: NtfyConfig?) {
        guard config != self.config else { return }
        testTask?.cancel()
        Diag.event(.ui, "settings.change", [
            "scope": "diagnostics", "key": "server", "from": self.config?.server.host() ?? "-", "to": config?.server.host() ?? "-",
            "auth": config?.token != nil,
        ])
        self.config = config
        storage.ntfy = config
        check = .untested
        apply()
    }

    func setName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != self.name else { return }
        log("name", from: self.name, to: name)
        self.name = name
        storage.diagName = name
        apply()
    }

    func setLive(_ on: Bool) {
        guard on != sendsLive else { return }
        log("live", from: sendsLive, to: on)
        sendsLive = on
        storage.diagLive = on
        apply()
    }

    func setDetailed(_ on: Bool) {
        guard on != detailed else { return }
        log("detail", from: detailed ? "detailed" : "standard", to: on ? "detailed" : "standard")
        detailed = on
        storage.diagDetailed = on
        apply()
    }

    func setButton(_ on: Bool) {
        guard on != showsButton else { return }
        log("button", from: showsButton, to: on)
        showsButton = on
        storage.diagButton = on
        apply()
    }

    /// Sends a test message. Reaching the server also resumes a live log a refused token had stopped.
    func test() {
        guard let config else { return }
        testTask?.cancel()
        check = .testing
        let message = NtfyMessage(title: title, text: "Test: this iPhone can send its diagnostic log here.", tags: ["white_check_mark"])
        testTask = Task {
            let started = ContinuousClock.now
            let outcome = await NtfyClient.send(config.publish(message), session: DiagLog.shared.session)
            guard !Task.isCancelled else { return }
            let result: Check = switch outcome.answer {
            case .accepted: .sent
            case .needsToken: .needsToken
            case .refused: .refused
            case nil: .unreachable
            case .attachmentRefused, .rateLimited, .serverError, .unexpected: .failed(outcome.status ?? 0)
            }
            check = result
            Diag.event(.integration, "ntfy.test", [
                "result": "\(result)", "status": outcome.status, "error": outcome.error, "ms": Diag.ms(since: started),
            ], result == .sent ? .info : .notice)
            if result == .sent { apply() }
        }
    }

    /// Delete All Local Data, after the storage is erased: back to not set up, with the journal gone.
    func eraseAll() {
        testTask?.cancel()
        config = nil
        name = ""
        sendsLive = true
        detailed = false
        showsButton = false
        check = .untested
        DiagLog.shared.erase()
        apply()
    }

    private func apply() {
        DiagHub.setThreshold(detailed ? .debug : .info)
        DiagLog.shared.configure(DiagLog.Setup(config: config, live: sendsLive, title: title))
        ReportButton.shared.setEnabled(showsButton && config != nil)
    }

    private func log(_ key: String, from old: Any, to new: Any) {
        Diag.event(.ui, "settings.change", ["scope": "diagnostics", "key": key, "from": old, "to": new])
    }
}
