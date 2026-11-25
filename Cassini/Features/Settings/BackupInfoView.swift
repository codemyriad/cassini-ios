import SwiftUI
import CassiniEngine
import CassiniNotebook

struct BackupSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BackupModel.self) private var backup
    @Environment(ErrorPresenter.self) private var errors
    @Environment(LibraryStore.self) private var library
    @Environment(ExportStore.self) private var exports
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var archiveExport: ArchiveExportModel
    private var pad: Bool { sizeClass == .regular }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.cloudBackup }, set: { change(cloud: $0) })) {
                backupLabel(SettingsPhase2Copy.backupMeetings, subtitle: SettingsPhase2Copy.backupMeetingsSubtitle)
            }
            .toggleStyle(TopAlignedSwitchToggleStyle())
            .accessibilityIdentifier("cloudBackupToggle")
            Toggle(isOn: Binding(get: { settings.includeSavedVoicesInBackups }, set: { change(voices: $0) })) {
                backupLabel(SettingsPhase2Copy.backupVoices,
                            subtitle: pad ? SettingsPhase2Copy.backupVoicesDescriptionIpad : SettingsPhase2Copy.backupVoicesDescriptionIphone)
            }
            .toggleStyle(TopAlignedSwitchToggleStyle())
            .accessibilityIdentifier("includeSavedVoicesToggle")
        }
        .disabled(backup.updating || !backup.ready)
        Section {
            NavigationLink(SettingsPhase2Copy.backupMoreDetailRow) { BackupInfoView() }
                .accessibilityIdentifier("backupInfoRow")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        detailHeading(SettingsPhase2Copy.backupIncludedHeading)
                        Text(SettingsPhase2Copy.backupIncludedLead)
                            .font(.subheadline).foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            inclusion(SettingsPhase2Copy.backupRowMeetings, detail: SettingsPhase2Copy.backupRowMeetingsDetail,
                                      included: presentation.meetingsIncluded, id: "backupStatusMeetings")
                            detailDivider
                            inclusion(SettingsPhase2Copy.backupRowSettings, detail: SettingsPhase2Copy.backupRowSettingsDetail,
                                      included: true, id: "backupStatusSettings")
                            detailDivider
                            inclusion(SettingsPhase2Copy.savedVoices, detail: SettingsPhase2Copy.backupRowVoicesDetail,
                                      included: presentation.voicesIncluded, id: "backupStatusVoices")
                            detailDivider
                            inclusion(SettingsPhase2Copy.backupRowModels, detail: SettingsPhase2Copy.backupRowModelsDetail,
                                      included: false, id: "backupStatusModels")
                        }.background(Color.card, in: RoundedRectangle(cornerRadius: 22))
                    }.id(Topic.contents)
                    VStack(alignment: .leading, spacing: 14) {
                        detailHeading(SettingsPhase2Copy.backupWho)
                        VStack(alignment: .leading, spacing: 16) {
                            explanation(Wave6Copy.backupInfoIcloudHeading, detail: SettingsPhase2Copy.backupWhoIcloud)
                            explanation(SettingsPhase2Copy.backupWhoComputer, detail: SettingsPhase2Copy.backupWhoComputerDetail)
                            explanation(SettingsPhase2Copy.backupWhoZip, detail: SettingsPhase2Copy.backupWhoZipDetail)
                                .accessibilityIdentifier("backupZipReader")
                        }.padding(.horizontal, 16)
                        Text(SettingsPhase2Copy.backupCassiniNever).font(.footnote).foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
                    }.id(Topic.readers)
                }.padding(.horizontal, 16).padding(.vertical, 20).readableWidth()
            }
            .background(Color.paper)
            .accessibilityIdentifier("backupInfo")
            .onAppear { if topic == .readers { proxy.scrollTo(Topic.readers, anchor: .top) } }
        }
        .navigationTitle(SettingsPhase2Copy.moreDetail).navigationBarTitleDisplayMode(.inline)
    }

    private func inclusion(_ title: String, detail: String, included: Bool, id: String) -> some View {
        BackupInclusionRow(title: title, detail: detail, included: included)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .accessibilityIdentifier(id)
    }

    private func explanation(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Color.ink)
            Text(detail).font(.subheadline).foregroundStyle(Color.muted)
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailHeading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.muted)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
    }
    private var detailDivider: some View { Divider().overlay(Color.line).padding(.horizontal, 16) }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var contentHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(SettingsStore.self) private var settings
    @Environment(BackupModel.self) private var backup
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            content.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight > 0 ? contentHeight : maximumHeight, maximumHeight))
        .background(Color.raised, in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).stroke(Color.line, lineWidth: 0.5).allowsHitTesting(false) }
        .compositingGroup()
        .shadow(color: Color.shadow, radius: 16, y: 4)
        .disabled(backup.updating)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backupNotice")
    }

    private var pad: Bool { sizeClass == .regular }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "icloud").font(.title2).foregroundStyle(Color.accentInk).accessibilityHidden(true)
                    Spacer()
                    dismissButton
                }
                Text(SettingsPhase2Copy.backupNoticeTitle).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "icloud").font(.title2).foregroundStyle(Color.accentInk).accessibilityHidden(true)
                    Text(SettingsPhase2Copy.backupNoticeTitle).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    dismissButton
                }
            }
            Text(pad ? SettingsPhase2Copy.backupNoticeBodyIpad : SettingsPhase2Copy.backupNoticeBodyIphone)
                .font(.subheadline).foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { keepButton; leaveOutButton }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { keepButton; leaveOutButton }
                    VStack(alignment: .leading, spacing: 8) { keepButton; leaveOutButton }
                }
            }
        }.padding(16)
    }

    private var dismissButton: some View {
        Button { settings.dismissBackupNotice() } label: {
            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).foregroundStyle(Color.muted)
            .accessibilityLabel(Wave6Copy.backupPhoneOnlyCardCloseA11y)
            .accessibilityIdentifier("backupNoticeDismiss")
    }

    private var keepButton: some View {
        Button { settings.dismissBackupNotice() } label: {
            Text(SettingsPhase2Copy.backupNoticeKeep).font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.neutralTint, in: Capsule()).foregroundStyle(Color.ink)
        }.buttonStyle(.plain).accessibilityIdentifier("backupNoticeKeep")
    }

    private var leaveOutButton: some View {
        Button {
            Task {
                do { try await backup.update(cloud: false, voices: settings.includeSavedVoicesInBackups, dismissNotice: true) }
                catch { errors.present(error.localizedDescription) }
            }
        } label: {
            Text(SettingsPhase2Copy.backupNoticeLeaveOut).font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.neutralTint, in: Capsule()).foregroundStyle(Color.ink)
        }.buttonStyle(.plain).accessibilityIdentifier("backupNoticeExclude")
    }
}
