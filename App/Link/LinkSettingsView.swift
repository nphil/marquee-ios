import CoreImage
import CoreImage.CIFilterBuiltins
import MarqueeCore
import SwiftUI
import UIKit

/// Settings › Linked Phones (DESIGN §8.10): the plugin's switch, this phone's name, the linked phones,
/// and the two halves of linking one.
struct LinkSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var sheet: Sheet?
    @State private var unlinking: LinkedPhone?

    private enum Sheet: String, Identifiable {
        case code, scan
        var id: String { rawValue }
    }

    var body: some View {
        let link = session.link
        List {
            Section {
                Toggle("Linked Phones", isOn: Binding(get: { link.isEnabled }, set: { link.setEnabled($0) }))
                    .accessibilityIdentifier("link.enabled")
            } footer: {
                Text("Two iPhones with Marquee, linked once, can control each other when they are near each other with Wi-Fi switched on (it needn’t be connected to a network), or on the same Wi-Fi: either one becomes the remote for the TV or glasses the other drives, or for what it plays.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            if link.isEnabled {
                Section {
                    TextField("Name", text: $name, prompt: Text(link.name))
                        .submitLabel(.done)
                        .onSubmit { link.setName(name) }
                        .accessibilityIdentifier("link.name")
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("The name linked phones show for this one.")
                        .foregroundStyle(theme.ink2)
                }
                .listRowBackground(theme.sheet)

                Section {
                    ForEach(link.phones) { phone in
                        LinkedPhoneRow(phone: phone, presence: link.presence[phone.id])
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Unlink", role: .destructive) { unlinking = phone }
                                    .accessibilityIdentifier("link.unlink")
                            }
                    }
                    Button("Show Link Code", systemImage: "qrcode") { sheet = .code }
                        .foregroundStyle(theme.accentText)
                        .accessibilityIdentifier("link.show")
                    Button("Scan Link Code", systemImage: "qrcode.viewfinder") { sheet = .scan }
                        .foregroundStyle(theme.accentText)
                        .accessibilityIdentifier("link.scan")
                } header: {
                    Text("Phones")
                } footer: {
                    Text(link.isDenied
                        ? "Marquee can’t use the local network, so it can’t find linked phones. Turn on Local Network for Marquee in the iPhone’s Settings › Privacy & Security."
                        : "One iPhone shows its link code, the other scans it. Home then offers to control a linked phone while it plays or drives a big screen.")
                        .foregroundStyle(link.isDenied ? theme.warning : theme.ink2)
                        .accessibilityIdentifier("link.footer")
                }
                .listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Linked Phones")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = link.customName }
        .onDisappear { link.setName(name) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .code: LinkCodeView()
            case .scan: LinkScanView()
            }
        }
        .confirmationDialog(
            "Unlink This Phone?",
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            titleVisibility: .visible,
            presenting: unlinking
        ) { phone in
            Button("Unlink", role: .destructive) { link.unlink(phone.id) }
                .accessibilityIdentifier("link.unlink.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { phone in
            Text("Neither iPhone can control the other until they are linked again. \(phone.name) forgets this iPhone too when it is in reach.")
        }
    }
}

/// A linked phone, and whether it is connected and what it shows.
private struct LinkedPhoneRow: View {
    let phone: LinkedPhone
    let presence: PhoneLink.Presence?
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(phone.name)
                    .textRole(.body)
                    .foregroundStyle(theme.ink)
                Text(state)
                    .textRole(.caption)
                    .foregroundStyle(presence == nil ? theme.ink3 : theme.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("link.phone")
            Spacer(minLength: Space.s3)
            if presence?.status?.isControllable == true {
                Button("Control") { session.link.control(phone.id) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.accentText)
                    .accessibilityLabel("Control \(phone.name)")
                    .accessibilityIdentifier("link.control")
            }
        }
    }

    private var state: String {
        guard let presence else { return "Not connected" }
        guard let status = presence.status else { return "Connected" }
        switch status.screen {
        case .tv?: return "Connected · Driving a TV"
        case .glasses?: return "Connected · Driving XR glasses"
        case nil: return status.nowPlaying.map { "Connected · Playing \($0.title)" } ?? "Connected"
        }
    }
}

/// Show Link Code: the code the other phone scans. It is made when the screen opens, links one phone,
/// and is gone when the screen closes.
struct LinkCodeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var code: UIImage?

    var body: some View {
        let link = session.link
        NavigationStack {
            VStack(spacing: Space.s5) {
                Spacer()
                switch link.inviteOutcome {
                case .linked(let name)?:
                    LinkResultView(outcome: .linked(name))
                case .failed(let message)?:
                    LinkResultView(outcome: .failed(message))
                case nil:
                    if let code {
                        Image(uiImage: code)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: Size.linkCode, height: Size.linkCode)
                            .accessibilityLabel("Link code for \(link.name)")
                            .accessibilityIdentifier("link.code")
                    }
                    Text(link.name)
                        .textRole(.headline)
                        .foregroundStyle(theme.ink)
                    Text("On the other iPhone, open Marquee › Settings › Linked Phones › Scan Link Code. Keep both iPhones near each other with Wi-Fi switched on, or on the same Wi-Fi.")
                        .textRole(.body)
                        .foregroundStyle(theme.ink2)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(Space.inset)
            .frame(maxWidth: .infinity)
            .background(theme.canvas)
            .navigationTitle("Link Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("link.code.done")
                }
            }
        }
        .onAppear {
            link.openInvite()
            code = link.invite.flatMap { LinkCode.image(for: $0.url.absoluteString) }
        }
        .onDisappear { link.closeInvite() }
    }
}

/// How linking ended, on the screen of either phone.
struct LinkResultView: View {
    let outcome: PhoneLink.Outcome
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s3) {
            switch outcome {
            case .linked(let name):
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(theme.positive)
                Text("Linked with \(name)")
                    .textRole(.title)
                    .foregroundStyle(theme.ink)
                    .accessibilityIdentifier("link.linked")
                Text("Both iPhones list each other in Linked Phones now.")
                    .textRole(.body)
                    .foregroundStyle(theme.ink2)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(theme.warning)
                Text("Not Linked")
                    .textRole(.title)
                    .foregroundStyle(theme.ink)
                    .accessibilityIdentifier("link.failed")
                Text(message)
                    .textRole(.body)
                    .foregroundStyle(theme.ink2)
            }
        }
        .multilineTextAlignment(.center)
    }
}

enum LinkCode {
    /// The code with its four-module quiet zone, one pixel a module, to be scaled up without smoothing. A
    /// QR code is dark on light whatever the theme: scanners read it reliably only that way.
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let quiet: CGFloat = 4
        let bounds = CGRect(x: 0, y: 0, width: code.extent.width + 2 * quiet, height: code.extent.height + 2 * quiet)
        let framed = code.transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            .composited(over: CIImage(color: .white).cropped(to: bounds))
        guard let image = CIContext().createCGImage(framed, from: bounds) else { return nil }
        return UIImage(cgImage: image)
    }
}
