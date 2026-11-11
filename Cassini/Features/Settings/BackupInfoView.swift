import SwiftUI

/// "Learn more" under Settings, Moving and backup: what moves, where the copy lives, who could read it, and how to keep
/// a copy yourself. Explanation only: it reads no setting and changes nothing (iOS does not tell apps whether a backup
/// ran or where it went). DRAFT wording, see `BackupDraftCopy`.
struct BackupInfoView: View {
    var body: some View {
        List {
            Section {
                paragraph(BackupDraftCopy.icloud)
                paragraph(BackupDraftCopy.icloudPrivate)
                paragraph(BackupDraftCopy.icloudLeaveOut)
            } header: {
                header(BackupDraftCopy.icloudHeading)
            }
            Section {
                paragraph(BackupDraftCopy.computer)
            } header: {
                header(BackupDraftCopy.computerHeading)
            }
            Section {
                paragraph(BackupDraftCopy.savedVoicesStay)
                paragraph(BackupDraftCopy.models)
            } header: {
                header(BackupDraftCopy.savedVoicesHeading)
            }
            Section {
                paragraph(BackupDraftCopy.exportHint)
            } header: {
                header(BackupDraftCopy.copyHeading)
            }
        }
        .paperListBackground()
        .readableListWidth()
        .navigationTitle(Text(verbatim: BackupDraftCopy.title)).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("backupInfo")
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Color.muted)
    }
}
