import Foundation

/// Manages security-scoped bookmark access for the user-chosen save directory.
/// In sandbox mode, a raw file path is not enough — we need a bookmark that the
/// system can resolve to regrant access across app launches.
enum SaveDirectoryAccess {

    private static let bookmarkKey = "saveDirectoryBookmark"
    private static let pathKey = "saveDirectory"

    /// The user's real home directory. `NSHomeDirectory()` and `FileManager.homeDirectory…` answer
    /// the sandbox container when a build is sandboxed; `getpwuid` answers the real home either way,
    /// which is what a default save folder has to name.
    static let homeDirectory: URL = {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            let real = String(cString: path)
            if real.hasPrefix("/") { return URL(fileURLWithPath: real, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// The shipped default save folder: the user's Documents, written directly because macshot is
    /// not sandboxed. Saving must not ask for a folder, so this is what a fresh install saves to.
    static var defaultDirectory: URL {
        homeDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    /// How the default folder reads in Settings and in the Save tooltip.
    static var defaultDisplayPath: String { "~/Documents" }

    /// Save both the path (for display) and the security-scoped bookmark (for sandbox access).
    static func save(url: URL) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } else {
            // Bookmark creation failed — clear any stale bookmark so we don't
            // keep granting access to an old folder that no longer matches path.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    /// Resolve the configured save directory, starting sandbox-scoped access,
    /// but return `nil` when no valid security-scoped bookmark exists. Use this
    /// for writes that must succeed in the sandbox — `nil` means the caller
    /// should prompt the user to choose a folder. Mirrors
    /// `resolveRecordingDirectoryIfAccessible()`.
    /// Caller **must** call `stopAccessing(url:)` when done writing.
    static func resolveIfAccessible() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        // Re-creating a security-scoped bookmark requires active scoped access,
        // so this has to come after startAccessing — doing it before meant the
        // refresh always failed and the bookmark stayed stale on every save.
        if isStale {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }

    /// Resolve the save directory URL and start sandbox-scoped access.
    /// Caller **must** call `stopAccessing(url:)` when done writing.
    ///
    /// ⚠️ This **always** returns a URL, falling back to the stored raw path or
    /// `~/Pictures` when no bookmark exists — but that fallback has **no**
    /// sandbox write access, so `write(to:)` will fail. Prefer
    /// `resolveIfAccessible()` for writes that must work in the sandbox.
    static func resolve() -> URL {
        if let url = resolveIfAccessible() { return url }
        if let path = UserDefaults.standard.string(forKey: pathKey) {
            return URL(fileURLWithPath: path)
        }
        return defaultDirectory
    }

    /// The folder a Save writes into without asking: the configured bookmark when there is one,
    /// else the shipped `~/Documents`. `nil` means the user configured another folder whose
    /// bookmark is gone, so the caller has to ask for it again.
    /// `scoped` tells the caller whether it holds sandbox-scoped access it must release.
    static func resolveForSave() -> (url: URL, scoped: Bool)? {
        if let url = resolveIfAccessible() { return (url, true) }
        let configured = UserDefaults.standard.string(forKey: pathKey)
        // A stored path equal to the default is a folder that needs no bookmark (the app is not
        // sandboxed), so it saves directly like the unconfigured case.
        if configured == nil || configured == defaultDirectory.path {
            try? FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
            return (defaultDirectory, false)
        }
        return nil
    }

    /// Resolve the directory URL **without** starting scoped access.
    /// Use this for NSSavePanel/NSOpenPanel `directoryURL` hints — they handle
    /// their own sandbox access via powerbox.
    static func directoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: pathKey) {
            return URL(fileURLWithPath: path)
        }
        return defaultDirectory
    }

    /// Stop accessing the security-scoped resource after writing is complete.
    static func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// The display path for the settings UI.
    static var displayPath: String {
        UserDefaults.standard.string(forKey: pathKey) ?? defaultDisplayPath
    }

    // MARK: - Recording save directory (optional, falls back to general)

    private static let recBookmarkKey = "recordingSaveDirectoryBookmark"
    private static let recPathKey = "recordingSaveDirectory"

    static func saveRecordingDirectory(url: URL) {
        UserDefaults.standard.set(url.path, forKey: recPathKey)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: recBookmarkKey)
        }
    }

    static func clearRecordingDirectory() {
        UserDefaults.standard.removeObject(forKey: recPathKey)
        UserDefaults.standard.removeObject(forKey: recBookmarkKey)
    }

    /// Like resolveRecordingDirectory(), but returns nil if no valid security-scoped bookmark exists.
    /// Use this to decide whether to fall back to a Save As panel.
    static func resolveRecordingDirectoryIfAccessible() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: recBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        // Same ordering requirement as resolveIfAccessible: refreshing a
        // security-scoped bookmark needs active scoped access.
        if isStale {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: recBookmarkKey)
            }
        }
        return url
    }

    static func recordingDirectoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: recPathKey) {
            return URL(fileURLWithPath: path)
        }
        return directoryHint()
    }

    static var recordingDisplayPath: String {
        UserDefaults.standard.string(forKey: recPathKey) ?? L("Same as screenshots")
    }
}
