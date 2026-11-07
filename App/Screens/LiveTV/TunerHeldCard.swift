import MarqueeCore
import SwiftUI

/// A channel would not tune because a Plex recording has the tuner (docs/LIVE-TV.md §2.3): the card says
/// which one, and Stop Recording ends it and tunes the channel again. A series rule can be deleted with it.
struct TunerHeldCard: View {
    let model: LivePlaybackModel
    let recording: ScheduledRecording
    let close: () -> Void

    @Environment(\.theme) private var theme
    @State private var confirmsStop = false

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "record.circle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.danger)
                .accessibilityHidden(true)
            Text(recording.tunerHeldSentence)
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Stop the recording to watch another channel.")
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
                Button("Close", action: close)
                    .buttonStyle(PlayerPillStyle())
            }
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: 480)
        .onAppear { Haptics.error() }
        .confirmationDialog("Stop recording \(recording.title)?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop Recording", role: .destructive) { model.stopHolder(deletingSeries: false) }
            if model.store.offersSeriesDeletion(recording) {
                Button("Stop and Delete the Series Rule", role: .destructive) { model.stopHolder(deletingSeries: true) }
            }
        } message: {
            Text("The tuner is freed at once and this channel tunes again.")
        }
        .accessibilityIdentifier("liveplayer.tunerHeld")
    }
}
