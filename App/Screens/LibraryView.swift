import SwiftUI

struct LibraryView: View {
    var body: some View {
        EmptyState(title: "Not signed in", message: "Sign in to Plex to browse your movies and shows.", systemImage: "film.stack")
            .navigationTitle("Library")
    }
}
