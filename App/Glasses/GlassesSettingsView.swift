import MarqueeCore
import SwiftUI

/// The XR glasses plugin's settings: on or off, what a connected display is for, tilt, and the
/// remote's gestures.
struct GlassesSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let glasses = session.glasses
        List {
            Section {
                Toggle("XR Glasses", isOn: Binding(get: { glasses.isEnabled }, set: { glasses.setEnabled($0) }))
                    .accessibilityIdentifier("glasses.enabled")
                if glasses.isEnabled {
                    Picker("When Glasses Connect", selection: Binding(get: { glasses.use }, set: { glasses.setUse($0) })) {
                        ForEach(GlassesUse.allCases, id: \.self) { use in
                            Text(use.title).tag(use)
                        }
                    }
                    .accessibilityIdentifier("glasses.use")
                }
            } footer: {
                Text("Glasses such as the Viture Pro connect to the iPhone as a display. As XR glasses they get Marquee’s own screen, and the iPhone becomes a remote that works without looking at it. Off, the glasses mirror the phone.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            if glasses.isEnabled {
                Section {
                    Toggle("Tilt While Holding", isOn: Binding(get: { glasses.tiltEnabled }, set: { glasses.setTilt($0) }))
                        .accessibilityIdentifier("glasses.tilt")
                } footer: {
                    Text("Hold the thumb still after a swipe and tilt the phone to keep scrolling, or tilt while scrubbing to fine-tune. Motion is read only while the thumb is down.")
                        .foregroundStyle(theme.ink2)
                }
                .listRowBackground(theme.sheet)

                Section("Remote Gestures") {
                    gesture("Swipe", "Moves the focus; a hard flick keeps going")
                    gesture("Tap", "Chooses; in a video, plays or pauses")
                    gesture("Swipe in from the left edge", "Goes back")
                    gesture("Hold", "Opens the options; in a video, scrubs as the thumb slides")
                    gesture("Volume buttons", "Change the volume")
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("XR Glasses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gesture(_ name: String, _ effect: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(name)
                .textRole(.body)
                .foregroundStyle(theme.ink)
            Text(effect)
                .textRole(.caption)
                .foregroundStyle(theme.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}
