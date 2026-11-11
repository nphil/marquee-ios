import LiveEngine
import SwiftUI

@main
struct MarqueeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var session = AppSession()

    init() {
        // Live TV's timeshift buffers go with their stream; a run that crashed or that the system ended left its own.
        TimeshiftBuffer.removeLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(themeStore)
                .environment(session)
        }
    }
}
