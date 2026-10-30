import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject var updater: UpdateController
    @ObservedObject var controller: DictationController

    var body: some View {
        Section(L10n.tr("Updates")) {
            LabeledContent(L10n.tr("Installed version"), value: updater.installedVersion)
            Picker(L10n.tr("Update channel"), selection: Binding(get: { updater.channel }, set: { updater.selectChannel($0) })) {
                ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
            }
            .id(localization.locale.identifier)
            .disabled(!updater.canChangeChannel)
            Text(L10n.tr("Beta includes prereleases. Returning to Stable does not downgrade Talkless."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.tr("Automatically check for updates"), isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))
            .disabled(!updater.canChangeAutomaticChecks)
            .help(L10n.tr("Checks every 30 minutes while Talkless is running. During dictation, checks wait until the next interval. Turning this off does not cancel an update already in progress."))
            Text(L10n.tr("Checks every 30 minutes. You choose when to download and install."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L10n.tr("Last checked")) {
                if let date = updater.lastUpdateCheckDate {
                    Text(date.formatted(.dateTime.year().month().day().hour().minute().locale(localization.locale)))
                } else {
                    Text(L10n.tr("Not checked yet"))
                }
            }
            .help(L10n.tr("The time of the last attempt, including checks that did not finish."))
            Button(updater.checkForUpdatesTitle) { updater.checkForUpdates(nil) }
                .disabled(controller.state != .idle || !updater.canCheckForUpdates)
            if let status = updater.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if updater.canChangeAutomaticChecks && !updater.canChangeChannel {
                Text(L10n.tr("Finish or dismiss the current update before changing channels."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
