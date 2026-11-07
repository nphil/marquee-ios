import SwiftUI

struct SearchView: View {
    var body: some View {
        EmptyState(title: "Not signed in", message: "Sign in to Plex to search your library.", systemImage: "magnifyingglass")
            .navigationTitle("Search")
    }
}
