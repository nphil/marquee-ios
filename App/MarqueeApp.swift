import SwiftUI

@main
struct MarqueeApp: App {
    @State private var themeStore = ThemeStore()
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(themeStore)
                .environment(session)
        }
    }
}
