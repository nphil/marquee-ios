import SwiftUI

struct HomeView: View {
    var body: some View {
        EmptyState(title: "Not signed in", message: "Sign in to Plex to see your library.", systemImage: "film.stack")
            .navigationTitle("Home")
    }
}
