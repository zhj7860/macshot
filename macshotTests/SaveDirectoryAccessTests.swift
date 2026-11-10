import XCTest

/// A capture's Save must never ask for a folder: the shipped default is the user's real
/// `~/Documents`, which the app reaches directly because it is not sandboxed.
final class SaveDirectoryAccessTests: XCTestCase {

    private let keys = ["saveDirectory", "saveDirectoryBookmark"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        // The domain's real values are put back in tearDown, so a developer's own
        // save folder survives a test run.
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testDefaultDirectoryIsTheRealDocumentsFolder() {
        let documents = SaveDirectoryAccess.defaultDirectory
        XCTAssertEqual(documents.lastPathComponent, "Documents")
        XCTAssertFalse(documents.path.contains("/Library/Containers/"),
                       "a container Documents folder is not the one Finder shows")
        XCTAssertTrue(documents.path.hasPrefix("/Users/"), "got \(documents.path)")
    }

    func testUnconfiguredSaveResolvesToTheDefaultWithoutAsking() throws {
        let target = try XCTUnwrap(SaveDirectoryAccess.resolveForSave(),
                                   "a fresh install must save without a folder picker")
        XCTAssertEqual(target.url.standardizedFileURL.path,
                       SaveDirectoryAccess.defaultDirectory.standardizedFileURL.path)
        XCTAssertFalse(target.scoped, "the default folder needs no security-scoped access")
    }

    func testDisplayPathAndHintDefaultToDocuments() {
        XCTAssertEqual(SaveDirectoryAccess.displayPath, "~/Documents")
        XCTAssertEqual(SaveDirectoryAccess.directoryHint()?.lastPathComponent, "Documents")
        XCTAssertEqual(SaveDirectoryAccess.resolve().lastPathComponent, "Documents")
    }

    func testStoredDefaultPathStillSavesWithoutAsking() throws {
        UserDefaults.standard.set(SaveDirectoryAccess.defaultDirectory.path, forKey: "saveDirectory")
        let target = try XCTUnwrap(SaveDirectoryAccess.resolveForSave())
        XCTAssertFalse(target.scoped)
    }

    func testCustomFolderWithoutABookmarkAsksAgain() {
        UserDefaults.standard.set("/tmp/macshot-somewhere-else", forKey: "saveDirectory")
        XCTAssertNil(SaveDirectoryAccess.resolveForSave(),
                     "a configured folder whose bookmark is gone has to be chosen again")
        XCTAssertEqual(SaveDirectoryAccess.displayPath, "/tmp/macshot-somewhere-else")
    }
}
