import Foundation

/// macshot used to ship inside the App Sandbox, so its Application Support folder, its history
/// and its preferences lived in the app container. The app is no longer sandboxed — a capture
/// saves straight into `~/Documents` without asking for a folder — so an update has to carry the
/// old container's data across once, or the first unsandboxed launch would look like every
/// capture and every setting was lost.
enum SandboxMigration {
    /// Set once the containers have been looked at, so a launch never repeats the work.
    static let markerKey = "sandboxContainerDataMoved"
    /// The folder macshot keeps under Application Support, in the container and out of it.
    static let appSupportFolder = "com.sw33tlie.macshot"

    /// Runs before anything reads preferences or Application Support.
    static func runIfNeeded(
        home: URL = SaveDirectoryAccess.homeDirectory,
        support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        bundleID: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) {
        guard let bundleID, !bundleID.isEmpty, !defaults.bool(forKey: markerKey) else { return }
        let container = home
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        guard FileManager.default.fileExists(atPath: container.path) else {
            // A fresh install never had a container: nothing to carry across.
            defaults.set(true, forKey: markerKey)
            return
        }
        importPreferences(
            from: container.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
            into: defaults)
        if let support {
            moveSupportFolder(
                from: container.appendingPathComponent("Library/Application Support/\(appSupportFolder)"),
                to: support.appendingPathComponent(appSupportFolder))
        }
        defaults.set(true, forKey: markerKey)
    }

    /// Copies only the keys this domain does not already have, so a setting the user changed in an
    /// unsandboxed build always wins over the container's old value.
    static func importPreferences(from plist: URL, into defaults: UserDefaults) {
        guard let legacy = NSDictionary(contentsOf: plist) as? [String: Any] else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// A move keeps the volume and the file dates; copying is the fallback when the destination is
    /// on another volume. An existing destination is never replaced.
    static func moveSupportFolder(from legacy: URL, to destination: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path),
              !manager.fileExists(atPath: destination.path) else { return }
        try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        if (try? manager.moveItem(at: legacy, to: destination)) != nil { return }
        if (try? manager.copyItem(at: legacy, to: destination)) != nil {
            try? manager.removeItem(at: legacy)
        }
    }
}
