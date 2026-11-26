import MarqueeCore
import LiveEngine
import SwiftUI

@main
struct MarqueeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var session: AppSession
    @State private var recordingAlerts: RecordingAlerts

    init() {
        // First, so the session's own start is in the log.
        Diag.start()
        // Live TV's timeshift buffers go with their stream; a run that crashed or that the system ended left its own.
        TimeshiftBuffer.removeLeftovers()
        let session = AppSession()
        let alerts = RecordingAlerts(defaults: .standard)
        alerts.watch = { [weak session] in
            guard let session, let library = session.library else { return nil }
            return .init(live: PlexLiveTV(library: library), key: .init(server: library.server.id, profile: session.user?.uuid ?? "owner"))
        }
        RecordingRefresh.register(alerts)
        _session = State(initialValue: session)
        _recordingAlerts = State(initialValue: alerts)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(themeStore)
                .environment(session)
                .environment(recordingAlerts)
        }
    }
}
