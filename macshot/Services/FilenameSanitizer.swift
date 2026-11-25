import Foundation

/// Shared boundary for template results and direct recording display names.
/// Returns an extension-free component; callers choose an appropriate fallback.
enum FilenameSanitizer {
    nonisolated static func sanitize(_ value: String, maximumBytes: Int = 200) -> String {
        guard maximumBytes > 0 else { return "" }
        var cleaned = ""
        var pendingWhitespace = false
        for scalar in value.unicodeScalars {
            switch scalar {
            case "/", ":", "|", "\0":
                pendingWhitespace = false
                cleaned.append("-")
            default:
                // C0/C1 controls are not useful in names or XML manifests.
                // Preserve format characters such as the joiners in emoji.
                guard scalar.value >= 0x20, !(0x7F...0x9F).contains(scalar.value) else { continue }
                if scalar.properties.isWhitespace {
                    // Names stay space-free for shells, URLs and uploads: a
                    // whitespace run between words becomes one dash. Leading
                    // and trailing runs, and runs next to an existing dash,
                    // disappear instead of adding another one.
                    if !cleaned.isEmpty, cleaned.last != "-" { pendingWhitespace = true }
                } else {
                    if pendingWhitespace {
                        cleaned.append("-")
                        pendingWhitespace = false
                    }
                    cleaned.unicodeScalars.append(scalar)
                }
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var bytes = 0
        for character in cleaned {
            let length = String(character).utf8.count
            guard length <= maximumBytes - bytes else { break }
            result.append(character)
            bytes += length
        }
        // Capping may expose a dot/space that was in the middle of the name.
        while let last = result.last, last == "." || last.isWhitespace { result.removeLast() }
        return result
    }
}
