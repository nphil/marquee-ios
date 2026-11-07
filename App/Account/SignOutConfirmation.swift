import SwiftUI

extension View {
    /// Sign-out is destructive (DESIGN §11): it asks first and names what goes. Cancel is the safe choice.
    func signOutConfirmation(isPresented: Binding<Bool>, session: AppSession) -> some View {
        confirmationDialog("Sign out of Plex?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { session.signOut() }
                .accessibilityIdentifier("signOut.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone forgets the Plex sign-in and the server list. Settings and themes stay.")
        }
    }
}
