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

/// Page-at-a-time navigation for long settings lists: previous, "page x of n", next.
struct SettingsPager: View {
    @Binding var page: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0)
                .accessibilityLabel(L10n.tr("Previous page"))
            Text(L10n.format("Page %lld of %lld", page + 1, pageCount))
                .font(.callout).monospacedDigit()
            Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(page >= pageCount - 1)
                .accessibilityLabel(L10n.tr("Next page"))
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    static func pageCount(items: Int, pageSize: Int) -> Int { max(1, (items + pageSize - 1) / pageSize) }
}
