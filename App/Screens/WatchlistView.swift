import SwiftUI

struct WatchlistView: View {
    var body: some View {
        EmptyState(title: "Not signed in", message: "Sign in to Plex to see your watchlist.", systemImage: "bookmark")
            .navigationTitle("Watchlist")
    }
}
