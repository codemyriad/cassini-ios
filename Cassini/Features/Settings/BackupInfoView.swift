import SwiftUI
import CassiniEngine
import CassiniNotebook

struct BackupSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BackupModel.self) private var backup
    @Environment(ErrorPresenter.self) private var errors
    @Environment(LibraryStore.self) private var library
    @Environment(ExportStore.self) private var exports
    @Bindable var archiveExport: ArchiveExportModel

    private var presentation: BackupPresentation {
        .init(cloud: settings.cloudBackup, voices: settings.includeSavedVoicesInBackups)
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "icloud").font(.title2).foregroundStyle(Color.accentInk).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.cloudBackup ? SettingsPhase2Copy.backupAnswer : SettingsPhase2Copy.backupExcluded)
                        .font(.headline).accessibilityIdentifier("backupAnswer")
                    Text(settings.cloudBackup ? SettingsPhase2Copy.backupAnswerBody : Wave6Copy.backupCloudBodyOffIos)
                        .font(.subheadline).foregroundStyle(Color.muted)
                }
            }.padding(.vertical, 6)
        }.listRowBackground(Color.accentTint)
        Section {
            Toggle(isOn: Binding(get: { settings.cloudBackup }, set: { change(cloud: $0) })) {
                backupLabel(SettingsPhase2Copy.backupMeetings, subtitle: SettingsPhase2Copy.backupMeetingsSubtitle)
            }.accessibilityIdentifier("cloudBackupToggle")
            Toggle(isOn: Binding(get: { settings.includeSavedVoicesInBackups }, set: { change(voices: $0) })) {
                backupLabel(SettingsPhase2Copy.backupVoices, subtitle: SettingsPhase2Copy.backupVoicesWhy)
            }.accessibilityIdentifier("includeSavedVoicesToggle")
        } footer: {
            Text(presentation.voicesIncluded
                 ? Wave6Copy.backupIncludeSavedVoicesSubtitleIos : Wave6Copy.backupIncludeSavedVoicesSubtitleOffIos)
        }
        .disabled(backup.updating || !backup.ready)
        Section {
            NavigationLink(Wave6Copy.backupInfoWhatHeading) { BackupInfoView() }
                .accessibilityIdentifier("backupInfoRow")
            NavigationLink(SettingsPhase2Copy.backupWho) { BackupInfoView(topic: .readers) }
                .accessibilityIdentifier("backupReadersRow")
        } header: { Text(SettingsPhase2Copy.moreDetail) }
        Section {
            Button {
                archiveExport.start(ArchiveSelection.ids(library.notes), exports: exports, errors: errors)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Color.accentInk)
                        .frame(width: 30, height: 30).background(Color.accentTint, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    backupLabel(BulkTransferCopy.all, subtitle: SettingsPhase2Copy.zipSubtitle)
                }.padding(.vertical, 4)
            }
            .accessibilityIdentifier("backupExportZIP")
            .disabled(!library.isLoaded || ArchiveSelection.ids(library.notes).isEmpty || archiveExport.progress != nil)
            ArchiveExportProgressView(model: archiveExport)
        } header: { Text(SettingsPhase2Copy.ownCopy) }
    }

    private func backupLabel(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Color.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.muted)
        }.fixedSize(horizontal: false, vertical: true)
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
    enum Topic: Hashable { case contents, readers }
    var topic: Topic = .contents
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let presentation = BackupPresentation(cloud: settings.cloudBackup, voices: settings.includeSavedVoicesInBackups)
        ScrollViewReader { proxy in
            List {
                Section {
                    inclusion(SettingsPhase2Copy.backupRowMeetings, detail: SettingsPhase2Copy.backupRowMeetingsDetail,
                              included: presentation.meetingsIncluded, id: "backupStatusMeetings")
                    inclusion(SettingsPhase2Copy.backupRowSettings, detail: SettingsPhase2Copy.backupRowSettingsDetail,
                              included: true, id: "backupStatusSettings")
                    inclusion(SettingsPhase2Copy.savedVoices, detail: SettingsPhase2Copy.backupRowVoicesDetail,
                              included: presentation.voicesIncluded, id: "backupStatusVoices")
                    inclusion(SettingsPhase2Copy.backupRowModels, detail: SettingsPhase2Copy.backupRowModelsDetail,
                              included: false, id: "backupStatusModels")
                } header: { Text(Wave6Copy.backupInfoWhatHeading) }
                .id(Topic.contents)
                Section {
                    explanation(Wave6Copy.backupInfoIcloudHeading, detail: SettingsPhase2Copy.backupWhoIcloud)
                    explanation(SettingsPhase2Copy.backupWhoComputer, detail: SettingsPhase2Copy.backupWhoComputerDetail)
                    explanation(SettingsPhase2Copy.backupWhoZip, detail: SettingsPhase2Copy.backupWhoZipDetail)
                        .accessibilityIdentifier("backupZipReader")
                } header: { Text(SettingsPhase2Copy.backupWho) } footer: { Text(SettingsPhase2Copy.backupCassiniNever) }
                .id(Topic.readers)
            }
            .paperListBackground().readableListWidth()
            .accessibilityIdentifier("backupInfo")
            .onAppear { if topic == .readers { proxy.scrollTo(Topic.readers, anchor: .top) } }
        }
        .navigationTitle(SettingsPhase2Copy.moreDetail).navigationBarTitleDisplayMode(.inline)
    }

    private func inclusion(_ title: String, detail: String, included: Bool, id: String) -> some View {
        BackupInclusionRow(title: title, detail: detail, included: included)
            .accessibilityIdentifier(id)
    }

    private func explanation(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(Color.ink)
            Text(detail).font(.subheadline).foregroundStyle(Color.muted)
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    }
}

private struct BackupInclusionRow: View {
    let title: String
    let detail: String
    let included: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Color.ink)
            Text(detail).font(.subheadline).foregroundStyle(Color.muted)
        }
    }
    private var status: some View {
        Text(included ? SettingsPhase2Copy.backupIncluded : SettingsPhase2Copy.backupExcluded)
            .font(.subheadline.weight(.semibold)).foregroundStyle(included ? Color.toneOK : Color.muted)
    }
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { label; status }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    status.multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            .accessibilityElement(children: .combine)
    }
}

/// Floats over the Library above CaptureBar. At large text sizes its content scrolls within
/// the available viewport, keeping both choices reachable without covering navigation or Record.
struct BackupNoticeCard: View {
    let maximumHeight: CGFloat
    @Environment(SettingsStore.self) private var settings
    @Environment(BackupModel.self) private var backup
    @Environment(ErrorPresenter.self) private var errors

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: maximumHeight)
        .background(Color.paper, in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).stroke(Color.muted.opacity(0.2), lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .disabled(backup.updating)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backupNotice")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "icloud").font(.title2).foregroundStyle(Color.accentInk).accessibilityHidden(true)
                Text(Wave6Copy.backupPhoneOnlyCardTitleIos).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Button { settings.dismissBackupNotice() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44).contentShape(Circle())
                }.buttonStyle(.plain).foregroundStyle(Color.muted)
                    .accessibilityLabel(Wave6Copy.backupPhoneOnlyCardCloseA11y)
                    .accessibilityIdentifier("backupNoticeDismiss")
            }
            Text(Wave6Copy.backupPhoneOnlyCardBody).font(.subheadline).foregroundStyle(Color.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { keepButton; leaveOutButton }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { keepButton; leaveOutButton }
            }
        }.padding(16)
    }

    private var keepButton: some View {
        Button { settings.dismissBackupNotice() } label: {
            Text(Wave6Copy.backupPhoneOnlyCardDismiss).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(Color.accentInk, in: Capsule()).foregroundStyle(Color.paper)
        }.buttonStyle(.plain).accessibilityIdentifier("backupNoticeKeep")
    }

    private var leaveOutButton: some View {
        Button {
            Task {
                do { try await backup.update(cloud: false, voices: settings.includeSavedVoicesInBackups, dismissNotice: true) }
                catch { errors.present(error.localizedDescription) }
            }
        } label: {
            Text(Wave6Copy.backupPhoneOnlyCardActionIos).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(Color.accentTint, in: Capsule()).foregroundStyle(Color.accentInk)
        }.buttonStyle(.plain).accessibilityIdentifier("backupNoticeExclude")
    }
}
