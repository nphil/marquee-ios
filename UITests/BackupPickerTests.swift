import XCTest

final class BackupPickerTests: XCTestCase {
    @MainActor
    func testExportedBackupOpensForReviewWithoutApplyingIt() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        openSettings(in: app)
        reveal("settings.backup", in: app).tap()
        tap("backup.now", in: app)

        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        // Files can save under the suggested name without exposing an editable filename.
        // The isolated simulator starts with an empty local Files library.
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        let name = "Marquee Backup \(date.string(from: .now))"
        save.tap()

        let restore = element("backup.restore", in: app)
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        restore.tap()
        let document = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        if !document.waitForExistence(timeout: 5), app.buttons["Recents"].exists { app.buttons["Recents"].tap() }
        XCTAssertTrue(document.waitForExistence(timeout: 15), "Files must offer the exported backup for restore")
        document.tap()
        if app.buttons["Open"].isHittable { app.buttons["Open"].tap() }
        waitForBar("Restore", in: app)
        XCTAssertTrue(element("restore.cancel", in: app).exists)
        XCTAssertTrue(reveal("restore.confirm", in: app).exists, "Selection must finish reading and reach review")
        try snap("backup-picked-for-review")
        tap("restore.cancel", in: app)
        waitForBar("Backup & Sync", in: app)
    }
}
