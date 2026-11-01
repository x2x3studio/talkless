import SwiftUI

/// Shared trailing columns for settings with a value and a reset action.
enum SettingsControlLayout {
    static let valueWidth: CGFloat = 184
    static let resetWidth: CGFloat = 64
    static let height: CGFloat = 28
}

extension View {
    /// Secondary explanatory text under a setting: caption size, wraps instead of truncating.
    func settingsNote() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
