import AppKit

/// Deep links into System Settings › Privacy & Security. Opening a pane never triggers a
/// permission prompt; prompts stay behind explicit setup guide and Settings actions.
enum SystemSettingsPane: String {
    case accessibility = "Privacy_Accessibility"
    case microphone = "Privacy_Microphone"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }

    @MainActor func open() { NSWorkspace.shared.open(url) }
}
