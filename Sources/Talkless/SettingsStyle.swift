import SwiftUI

extension View {
    /// Secondary explanatory text under a setting: caption size, wraps instead of truncating.
    func settingsNote() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
