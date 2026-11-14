import SwiftUI
import CassiniEngine

struct BackupSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BackupModel.self) private var backup
    @Environment(ErrorPresenter.self) private var errors

    var body: some View {
        Section {
            Toggle(Wave6Copy.backupCloudTitle, isOn: Binding(get: { settings.cloudBackup }, set: { change(cloud: $0) }))
                .accessibilityIdentifier("cloudBackupToggle")
            Text(settings.cloudBackup ? Wave6Copy.backupCloudBodyOn : Wave6Copy.backupCloudBodyOffIos)
                .font(.footnote).foregroundStyle(Color.muted)
            Toggle(Wave6Copy.backupIncludeSavedVoicesTitle, isOn: Binding(
                get: { settings.includeSavedVoicesInBackups }, set: { change(voices: $0) }))
                .accessibilityIdentifier("includeSavedVoicesToggle")
            Text(settings.includeSavedVoicesInBackups
                 ? Wave6Copy.backupIncludeSavedVoicesSubtitleIos : Wave6Copy.backupIncludeSavedVoicesSubtitleOffIos)
                .font(.footnote).foregroundStyle(Color.muted)
            NavigationLink(Wave6Copy.backupSettingsLearnMore) { BackupInfoView() }
                .accessibilityIdentifier("backupInfoRow")
        } header: { Text(Wave6Copy.backupSettingsHeading) }
        .disabled(backup.updating || !backup.ready)
    }

    private func change(cloud: Bool? = nil, voices: Bool? = nil) {
        Task {
            do { try await backup.update(cloud: cloud ?? settings.cloudBackup,
                                         voices: voices ?? settings.includeSavedVoicesInBackups) }
            catch { errors.present(error.localizedDescription) }
        }
    }
}

struct BackupInfoView: View {
    var body: some View {
        List {
            Section { Text(Wave6Copy.backupInfoWhatBody) } header: { Text(Wave6Copy.backupInfoWhatHeading) }
            Section {
                Text(Wave6Copy.backupInfoIcloudBody)
                Text(Wave6Copy.backupCloudBodyOffIos)
            } header: { Text(Wave6Copy.backupInfoIcloudHeading) }
            Section { Text(Wave6Copy.backupInfoIcloudComputerBody) } header: { Text(Wave6Copy.backupInfoIcloudComputerHeading) }
            Section { Text(Wave6Copy.settingsTransferExportHint) } header: { Text(Wave6Copy.backupInfoManualCopyHeading) }
        }
        .paperListBackground().readableListWidth()
        .navigationTitle(Wave6Copy.backupInfoTitle).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("backupInfo")
    }
}

struct BackupNoticeCard: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BackupModel.self) private var backup
    @Environment(ErrorPresenter.self) private var errors

    var body: some View {
        if backup.ready, settings.cloudBackup, !settings.backupNoticeDismissed {
            VStack(alignment: .leading, spacing: 12) {
                Text(Wave6Copy.backupPhoneOnlyCardTitleIos).font(.headline)
                Text(Wave6Copy.backupPhoneOnlyCardBody)
                Text(Wave6Copy.backupCloudBodyOffIos).font(.footnote).foregroundStyle(Color.muted)
                Button(Wave6Copy.backupPhoneOnlyCardActionIos) {
                    Task {
                        do { try await backup.update(cloud: false, voices: settings.includeSavedVoicesInBackups, dismissNotice: true) }
                        catch { errors.present(error.localizedDescription) }
                    }
                }
                Button(Wave6Copy.backupPhoneOnlyCardDismiss) { settings.dismissBackupNotice() }
                    .accessibilityLabel(Wave6Copy.backupPhoneOnlyCardCloseA11y)
            }
            .padding().background(Color.paper, in: RoundedRectangle(cornerRadius: 16))
            .disabled(backup.updating).accessibilityIdentifier("backupNotice")
        }
    }
}
