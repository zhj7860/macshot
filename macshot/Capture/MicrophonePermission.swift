import Cocoa

/// One microphone-permission prompt for every entry point (recording toolbar,
/// status menu, device menu) so the copy and the Settings link stay identical.
@MainActor
enum MicrophonePermission {
    static func showAccessAlert() {
        let alert = NSAlert()
        alert.messageText = L("Microphone Access Required")
        alert.informativeText =
            L("macshot needs microphone permission to record voice audio. Open System Settings to grant access.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
