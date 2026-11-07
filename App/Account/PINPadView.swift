import MarqueeCore
import SwiftUI
import UIKit

/// A protected profile's PIN. Plex Home PINs are 4 digits, so the fourth one submits; a wrong PIN
/// clears the dots and says so.
struct PINPadView: View {
    let profile: PlexHomeUser
    /// Called once the switch is done, to close the sheet.
    let onSwitched: @MainActor () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var digits = ""
    @State private var isChecking = false
    @State private var message: String?
    @State private var refusals = 0

    private static let length = 4

    var body: some View {
        // Side by side in landscape, where the stacked pad would run off the bottom of the screen.
        let layout = verticalSizeClass == .compact
            ? AnyLayout(HStackLayout(spacing: Space.s8))
            : AnyLayout(VStackLayout(spacing: Space.s6))
        GeometryReader { proxy in
            ScrollView {
                layout {
                    VStack(spacing: Space.s4) {
                        AvatarView(user: profile, size: Size.rowMin)
                        Text("Enter PIN")
                            .textRole(.headline)
                            .foregroundStyle(theme.ink)
                        PINDots(filled: digits.count, length: Self.length)
                            // The dots shake at a wrong PIN, as the iPhone's own passcode does. With Reduce
                            // Motion the message and the haptic say it alone.
                            .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : refusals) { dots, x in
                                dots.offset(x: x)
                            } keyframes: { _ in
                                KeyframeTrack {
                                    LinearKeyframe(-10.0, duration: 0.05)
                                    LinearKeyframe(10.0, duration: 0.07)
                                    LinearKeyframe(-7.0, duration: 0.07)
                                    LinearKeyframe(7.0, duration: 0.07)
                                    LinearKeyframe(0.0, duration: 0.06)
                                }
                            }
                        // The clear line holds the height while there is no message, so the keys never
                        // move under a finger between tries.
                        ZStack {
                            Color.clear.frame(height: Size.target)
                            status
                        }
                    }
                    Keypad(onDigit: { add($0) }, onDelete: { delete() })
                        .disabled(isChecking)
                }
                .padding(Space.inset)
                // Centred in the full-height sheet, so the keys sit within reach rather than under the bar.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(theme.canvas)
        .navigationTitle(profile.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var status: some View {
        if isChecking {
            ProgressView()
        } else if let message {
            HStack(spacing: Space.s2) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(theme.danger)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(theme.ink)
            }
            .textRole(.label)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pin.message")
        }
    }

    private func add(_ digit: Int) {
        guard digits.count < Self.length else { return }
        message = nil
        digits += String(digit)
        if digits.count == Self.length { submit(digits) }
    }

    private func delete() {
        guard !digits.isEmpty else { return }
        digits.removeLast()
    }

    private func submit(_ pin: String) {
        isChecking = true
        Task {
            do {
                try await session.switchUser(profile, pin: pin)
                Haptics.success()
                onSwitched()
            } catch PlexError.profilePINRejected {
                refuse("Wrong PIN")
            } catch {
                refuse("Couldn't switch. Check the connection.")
            }
            isChecking = false
        }
    }

    private func refuse(_ text: String) {
        Haptics.error()
        message = text
        digits = ""
        refusals += 1
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// One dot per digit, filled as they are typed. Outlines in ink2 keep the empty ones at 3:1 or more.
private struct PINDots: View {
    let filled: Int
    let length: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s4) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < filled ? theme.ink : .clear)
                    .overlay(Circle().strokeBorder(index < filled ? theme.ink : theme.ink2, lineWidth: 1.5))
                    .frame(width: Space.s3, height: Space.s3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(filled) of \(length) digits")
        .accessibilityIdentifier("pin.dots")
    }
}

/// Digits in the telephone layout, with Delete in the bottom right.
private struct Keypad: View {
    let onDigit: @MainActor (Int) -> Void
    let onDelete: @MainActor () -> Void

    private static let rows = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        Grid(horizontalSpacing: Space.s6, verticalSpacing: Space.s4) {
            ForEach(Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digit in
                        key(digit)
                    }
                }
            }
            GridRow {
                Color.clear
                    .frame(width: Size.target, height: Size.target)
                    .accessibilityHidden(true)
                key(0)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "delete.left")
                }
                .buttonStyle(.round)
                .accessibilityLabel("Delete")
                .accessibilityIdentifier("pin.delete")
            }
        }
        // The keys keep their 48 pt circles, so the digits stop growing where they would overflow them.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func key(_ digit: Int) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text(String(digit))
                .monospacedDigit()
        }
        .buttonStyle(.round)
        .accessibilityIdentifier("pin.\(digit)")
    }
}
