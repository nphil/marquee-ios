import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The backup file, declared in Info.plist as `com.nphil.marquee.backup` with the extension `marqueebackup`.
    static let marqueeBackup = UTType(exportedAs: "com.nphil.marquee.backup", conformingTo: .data)
}

/// A backup file for the system's file exporter. The bytes are sealed before they get here.
struct BackupDocument: FileDocument {
    static let readableContentTypes = [UTType.marqueeBackup]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
