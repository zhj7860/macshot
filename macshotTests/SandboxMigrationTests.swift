import XCTest

/// An update from a sandboxed build must find its history and settings: the container they lived
/// in is not the folder an unsandboxed macshot reads.
final class SandboxMigrationTests: XCTestCase {

    private let bundleID = "com.sw33tlie.macshot.migrationtest"
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "macshot.SandboxMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeContainer() throws -> (container: URL, support: URL) {
        let container = root
            .appendingPathComponent("home/Library/Containers/\(bundleID)/Data", isDirectory: true)
        let support = container.appendingPathComponent("Library/Application Support/\(SandboxMigration.appSupportFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("history"), withIntermediateDirectories: true)
        try Data("index".utf8).write(to: support.appendingPathComponent("history/index.json"))
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let legacy: [String: Any] = ["hotkeyKeyCode": 7, "playCopySound": false]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        try data.write(to: container.appendingPathComponent("Library/Preferences/\(bundleID).plist"))
        return (container, support)
    }

    private func run(support: URL) {
        SandboxMigration.runIfNeeded(
            home: root.appendingPathComponent("home"),
            support: root.appendingPathComponent("Application Support"),
            bundleID: bundleID,
            defaults: defaults)
    }

    func testSupportFolderAndPreferencesMoveOnce() throws {
        let (container, legacySupport) = try makeContainer()
        run(support: root.appendingPathComponent("Application Support"))

        let moved = root.appendingPathComponent("Application Support/\(SandboxMigration.appSupportFolder)/history/index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "history did not move out of the container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySupport.path), "the container folder should have moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path), "the container itself stays")
        XCTAssertEqual(defaults.integer(forKey: "hotkeyKeyCode"), 7)
        XCTAssertEqual(defaults.object(forKey: "playCopySound") as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: SandboxMigration.markerKey))
    }

    func testAValueSetInThisBuildIsNotOverwritten() throws {
        _ = try makeContainer()
        defaults.set(11, forKey: "hotkeyKeyCode")
        run(support: root.appendingPathComponent("Application Support"))
        XCTAssertEqual(defaults.integer(forKey: "hotkeyKeyCode"), 11)
    }

    func testARunWithoutAContainerIsANoOpThatMarksDone() {
        run(support: root.appendingPathComponent("Application Support"))
        XCTAssertTrue(defaults.bool(forKey: SandboxMigration.markerKey))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Application Support/\(SandboxMigration.appSupportFolder)").path))
    }

    func testAnExistingDestinationIsNeverReplaced() throws {
        _ = try makeContainer()
        let destination = root.appendingPathComponent("Application Support/\(SandboxMigration.appSupportFolder)/history/mine.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: destination)
        run(support: root.appendingPathComponent("Application Support"))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "mine")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Application Support/\(SandboxMigration.appSupportFolder)/history/index.json").path))
    }
}
