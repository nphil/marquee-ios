import SwiftUI

@main
struct MarqueeApp: App {
    @State private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(themeStore)
        }
    }
}
