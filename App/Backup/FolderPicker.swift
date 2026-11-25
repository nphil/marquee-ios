import UIKit
import UniformTypeIdentifiers

/// The Files folder picker, presented straight from UIKit's document picker. Its delegate reports every
/// outcome (a folder, a failure, a cancel), where SwiftUI's `fileImporter` on this page did nothing when Open
/// was tapped inside an iCloud Drive folder (0.1.88 on the iPhone).
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: FolderPicker?
    private let finish: (Result<URL, any Error>) -> Void

    private init(finish: @escaping (Result<URL, any Error>) -> Void) {
        self.finish = finish
    }

    /// Opens the picker over whatever is on screen. `finish` is called once, with the folder or the failure;
    /// cancelling reports `CocoaError.userCancelled`.
    static func present(_ finish: @escaping (Result<URL, any Error>) -> Void) {
        guard let top = topController() else {
            finish(.failure(CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "no screen"])))
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        picker.allowsMultipleSelection = false
        let owner = FolderPicker(finish: finish)
        picker.delegate = owner
        current = owner
        top.present(picker, animated: true)
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
        if let url = urls.first {
            finish(.success(url))
        } else {
            finish(.failure(CocoaError(.fileNoSuchFile)))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.current = nil
        finish(.failure(CocoaError(.userCancelled)))
    }
}
