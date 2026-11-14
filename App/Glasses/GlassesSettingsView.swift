import MarqueeCore
import SwiftUI

/// The big-screen plugin's settings (XR glasses and TVs): on or off, what a connected display is for, what
/// kind it is, the displays remembered, tilt, and the remote's gestures.
struct GlassesSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let glasses = session.glasses
        List {
            Section {
                Toggle("Big Screen", isOn: Binding(get: { glasses.isEnabled }, set: { glasses.setEnabled($0) }))
                    .accessibilityIdentifier("glasses.enabled")
                if glasses.isEnabled {
                    Picker("When a Display Connects", selection: Binding(get: { glasses.use }, set: { glasses.setUse($0) })) {
                        ForEach(BigScreenUse.allCases, id: \.self) { use in
                            Text(use.title).tag(use)
                        }
                    }
                    .accessibilityIdentifier("glasses.use")
                    Picker("Display Type", selection: Binding(get: { glasses.shownKind }, set: { glasses.setKind($0) })) {
                        ForEach(DisplayKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("glasses.kind")
                }
            } footer: {
                Text("XR glasses such as the Viture Pro, or a TV on USB-C video out or an HDMI adapter, connect to the iPhone as a display. Marquee’s own screen fills it, and the iPhone becomes a remote that works without looking at it. Mirror shows a copy of the phone, as without the plugin. iOS cannot tell glasses from a TV, so Display Type is remembered for each display; with none connected it is what a new display is taken for. A TV keeps clear of its edges and shows the theme’s own dark canvas; glasses show black, which is see-through.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            if glasses.isEnabled, let connected = glasses.display {
                Section("Connected Display") {
                    LabeledContent(connected.name ?? "Display") {
                        Text([connected.sizeLabel, "\(connected.refreshRate) Hz"].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(theme.ink2)
                    }
                    .accessibilityIdentifier("glasses.connected")
                    if let summary = glasses.navigator?.localSummary {
                        LabeledContent("Touch Delay") {
                            Text(summary).foregroundStyle(theme.ink2)
                        }
                        .accessibilityIdentifier("glasses.latency.local")
                    }
                    if let summary = glasses.navigator?.linkedSummary {
                        LabeledContent("Linked Phone Touch Delay") {
                            Text(summary).foregroundStyle(theme.ink2)
                        }
                        .accessibilityIdentifier("glasses.latency.linked")
                    }
                }
                .listRowBackground(theme.sheet)
            }

            if glasses.isEnabled, !glasses.displays.displays.isEmpty {
                Section {
                    ForEach(glasses.displays.displays) { display in
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(display.title)
                                .textRole(.body)
                                .foregroundStyle(theme.ink)
                            Text(display.summary)
                                .textRole(.caption)
                                .foregroundStyle(theme.ink2)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions {
                            Button("Forget", role: .destructive) { glasses.forget(display.key) }
                        }
                    }
                } header: {
                    Text("Remembered Displays")
                } footer: {
                    Text("Swipe a display to forget it; the next connection asks again.")
                        .foregroundStyle(theme.ink2)
                }
                .listRowBackground(theme.sheet)
            }

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
        .navigationTitle("Big Screen: XR Glasses & TV")
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
