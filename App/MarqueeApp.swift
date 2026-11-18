import LiveEngine
import SwiftUI

@main
struct MarqueeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var session: AppSession

    init() {
        // First, so the session's own start is in the log.
        Diag.start()
        // Live TV's timeshift buffers go with their stream; a run that crashed or that the system ended left its own.
        TimeshiftBuffer.removeLeftovers()
        _session = State(initialValue: AppSession())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(themeStore)
                .environment(session)
        }
    }
}
