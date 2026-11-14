import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit

/// Scan Link Code: the camera reads the other phone's code, and linking waits for a yes.
struct LinkScanView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = LinkCameraAccess.current
    @State private var found: LinkInvite?
    @State private var wrongCode = false
    @State private var linking = false
    @State private var outcome: PhoneLink.Outcome?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
                .navigationTitle("Scan Link Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(outcome == nil ? "Cancel" : "Done") { dismiss() }
                            .disabled(linking)
                            .accessibilityIdentifier("link.scan.close")
                    }
                }
        }
        .interactiveDismissDisabled(linking)
        .task {
            #if DEBUG
            if let invite = session.link.simulatedScan {
                found = invite
                return
            }
            #endif
            if access == .undecided { access = await LinkCameraAccess.request() }
        }
        .task(id: wrongCode) {
            guard wrongCode else { return }
            try? await Task.sleep(for: .seconds(2))
            wrongCode = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if let outcome {
            VStack(spacing: Space.s5) {
                LinkResultView(outcome: outcome)
                if case .failed = outcome, let found {
                    Button("Try Again") { link(found) }
                        .buttonStyle(.pill)
                        .disabled(linking)
                        .accessibilityIdentifier("link.retry")
                }
            }
            .padding(Space.inset)
        } else if let found {
            confirmation(found)
        } else {
            scanner
        }
    }

    @ViewBuilder
    private var scanner: some View {
        switch access {
        case .allowed:
            ZStack {
                LinkCamera { code in
                    guard let invite = LinkInvite(string: code) else {
                        wrongCode = true
                        return
                    }
                    found = invite
                }
                .ignoresSafeArea()
                .accessibilityLabel("Camera")
                .accessibilityHint("Point it at the link code on the other iPhone.")
                viewfinder
            }
        case .undecided:
            ProgressView()
        case .refused:
            notice("Camera access is off for Marquee. Allow it in Settings to scan the code.", button: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .unavailable:
            notice("This iPhone has no camera to scan with.")
        }
    }

    /// A square guide over the camera, edged in the danger colour for two seconds after reading a code that
    /// isn't a link code.
    private var viewfinder: some View {
        VStack(spacing: Space.s6) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(wrongCode ? theme.danger : theme.ink, lineWidth: 2)
                .frame(width: Size.linkCode, height: Size.linkCode)
            Text(wrongCode ? "That isn’t a Marquee link code." : "Point the camera at the code on the other iPhone.")
                .textRole(.headline)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .background(theme.sheet, in: Capsule())
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(Space.inset)
        .allowsHitTesting(false)
    }

    private func notice(_ text: String, button: String? = nil, action: @escaping () -> Void = {}) -> some View {
        VStack(spacing: Space.s5) {
            Text(text)
                .textRole(.body)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.center)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.pill)
            }
        }
        .padding(Space.inset)
    }

    private func confirmation(_ invite: LinkInvite) -> some View {
        VStack(spacing: Space.s5) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(theme.accent)
            Text("Link with \(invite.name)?")
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityIdentifier("link.confirm.title")
            Text("Either iPhone can then control what the other plays, whenever both are on the same Wi-Fi. Either can unlink at any time.")
                .textRole(.body)
                .foregroundStyle(theme.ink2)
            Button {
                link(invite)
            } label: {
                Text(linking ? "Linking…" : "Link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
            .disabled(linking)
            .accessibilityIdentifier("link.confirm")
        }
        .multilineTextAlignment(.center)
        .padding(Space.inset)
    }

    private func link(_ invite: LinkInvite) {
        linking = true
        Task {
            outcome = await session.link.join(invite)
            linking = false
        }
    }
}

enum LinkCameraAccess: Equatable {
    case allowed, undecided, refused, unavailable

    static var current: LinkCameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .undecided
        default: return .refused
        }
    }

    static func request() async -> LinkCameraAccess {
        await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .refused
    }
}

/// The camera's picture, reporting each QR payload it reads.
private struct LinkCamera: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        if let camera = Camera(delegate: context.coordinator) {
            view.previewLayer.session = camera.session
            context.coordinator.camera = camera
            camera.start()
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.camera?.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // The layer class above makes this cast always succeed.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        var camera: Camera?
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            // The delegate queue is the main queue.
            MainActor.assumeIsolated { found(codes) }
        }

        /// The camera reads a code many times a second; each distinct one counts once.
        private func found(_ codes: [String]) {
            guard let code = codes.first, code != lastCode else { return }
            lastCode = code
            onCode(code)
        }
    }

    /// A capture session on its own queue: starting and stopping block, so they stay off the main thread.
    final class Camera: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "Marquee.linkCamera")

        @MainActor
        init?(delegate: any AVCaptureMetadataOutputObjectsDelegate) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return nil }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return nil }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        func start() {
            queue.async { self.session.startRunning() }
        }

        func stop() {
            queue.async { self.session.stopRunning() }
        }
    }
}
