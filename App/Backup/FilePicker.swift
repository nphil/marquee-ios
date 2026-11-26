import UIKit
import UniformTypeIdentifiers

/// The Files pickers for the automatic backup's file, presented straight from UIKit. The folder picker never
/// returned from Open in iCloud Drive on the iPhone (0.1.93), while picking and exporting a file work, so the
/// backup is chosen as a file. Each outcome reaches `finish` once; cancelling reports `CocoaError.userCancelled`.
@MainActor
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    private static var current: FilePicker?
    private let finish: (Result<URL, any Error>) -> Void
    private let kind: String
    private let leftover: URL?

    private init(kind: String, leftover: URL?, finish: @escaping (Result<URL, any Error>) -> Void) {
        self.kind = kind
        self.leftover = leftover
        self.finish = finish
    }

    /// Lets the person pick an existing backup, which stays where it is.
    static func open(_ finish: @escaping (Result<URL, any Error>) -> Void) {
        present(kind: "open", leftover: nil, finish: finish) {
            UIDocumentPickerViewController(forOpeningContentTypes: [.marqueeBackup], asCopy: false)
        }
    }

    /// Lets the person pick where `file` is saved; the file moves there and the picker returns its new URL.
    static func save(_ file: URL, _ finish: @escaping (Result<URL, any Error>) -> Void) {
        present(kind: "save", leftover: file, finish: finish) {
            UIDocumentPickerViewController(forExporting: [file], asCopy: false)
        }
    }

    private static func present(
        kind: String, leftover: URL?, finish: @escaping (Result<URL, any Error>) -> Void,
        make: () -> UIDocumentPickerViewController
    ) {
        guard let top = topController() else {
            if let leftover { try? FileManager.default.removeItem(at: leftover) }
            finish(.failure(CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "no screen"])))
            return
        }
        let picker = make()
        picker.allowsMultipleSelection = false
        // The picker's delegate is weak, so the owner lives in `current` until an outcome arrives.
        let owner = FilePicker(kind: kind, leftover: leftover, finish: finish)
        picker.delegate = owner
        current = owner
        top.present(picker, animated: true) {
            Diag.event(.app, "backup.file", ["state": "presented", "kind": kind], .notice)
        }
    }

    private static func topController() -> UIViewController? {
        guard let scene = GlassesCenter.phoneScene() else { return nil }
        let windows = scene.windows.filter { !$0.isHidden && $0.windowLevel == .normal }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Self.current = nil
        Diag.event(.app, "backup.file", ["state": "picked", "kind": kind, "count": urls.count], .notice)
        if let url = urls.first {
            finish(.success(url))
        } else {
            discardLeftover()
            finish(.failure(CocoaError(.fileNoSuchFile)))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.current = nil
        Diag.event(.app, "backup.file", ["state": "cancelled", "kind": kind], .notice)
        discardLeftover()
        finish(.failure(CocoaError(.userCancelled)))
    }

    private func discardLeftover() {
        if let leftover { try? FileManager.default.removeItem(at: leftover) }
    }
}
