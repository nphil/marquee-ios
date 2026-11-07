import MarqueeCore
import SwiftUI

/// A channel would not tune because every tuner is taken (docs/LIVE-TV.md §2.3). With a Plex recording
/// behind it, the card names the recording, and Stop Recording ends it and tunes the channel again; a
/// series rule can be deleted with it. Otherwise it says the tuner is in use and offers Retry once.
struct TunerBusyCard: View {
    let model: LivePlaybackModel
    /// The recording holding the tuner, when the server shows one.
    let recording: ScheduledRecording?
    let close: () -> Void

    @Environment(\.theme) private var theme
    @State private var confirmsStop = false

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: recording == nil ? "tv.slash" : "record.circle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(recording == nil ? theme.warning : theme.danger)
                .accessibilityHidden(true)
            Text("Tuner busy")
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(recording?.tunerHeldSentence ?? "Another device is using the tuner")
                .textRole(.body)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.center)
            if let problem = model.holderProblem {
                Text(problem)
                    .textRole(.label)
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Space.s3) {
                if recording != nil {
                    Button {
                        confirmsStop = true
                    } label: {
                        HStack(spacing: Space.s2) {
                            if model.isStoppingHolder {
                                ProgressView()
                            } else {
                                Image(systemName: "stop.fill")
                                    .accessibilityHidden(true)
                            }
                            Text("Stop Recording")
                        }
                    }
                    .buttonStyle(PlayerPillStyle(prominent: true))
                    .disabled(model.isStoppingHolder)
                    .accessibilityIdentifier("liveplayer.stopRecording")
                } else {
                    Button("Retry", action: model.retry)
                        .buttonStyle(PlayerPillStyle(prominent: true))
                        .accessibilityIdentifier("player.retry")
                }
                Button("Close", action: close)
                    .buttonStyle(PlayerPillStyle())
            }
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: 480)
        .onAppear { Haptics.error() }
        .confirmationDialog("Stop recording \(recording?.title ?? "")?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Recording", role: .destructive) { model.stopHolder(deletingSeries: false) }
            if let recording, model.store.offersSeriesDeletion(recording) {
                Button("Stop and Delete the Series Rule", role: .destructive) { model.stopHolder(deletingSeries: true) }
            }
        } message: {
            Text("The tuner is freed at once and this channel tunes again.")
        }
        .accessibilityIdentifier("liveplayer.tunerBusy")
    }
}
