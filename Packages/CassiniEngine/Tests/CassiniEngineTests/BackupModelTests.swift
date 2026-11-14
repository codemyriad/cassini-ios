import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor @Suite struct BackupModelTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "backup.tests.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    func settings() -> SettingsStore { SettingsStore(defaults: defaults, clock: FakeClock()) }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    // Foundation reports the flag on the inode, not inherited flags. Backup excludes any item with an excluded ancestor.
    func excluded(_ url: URL) throws -> Bool {
        var value = URL(fileURLWithPath: url.path)
        while value.path != "/" {
            if try value.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true { return true }
            value.deleteLastPathComponent()
        }
        return false
    }
    func flag(_ url: URL) throws -> Bool {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    @Test func defaultsIncludeMeetingsAndVoicesAndMigrateLegacyVoicesFlag() async throws {
        defer { cleanup() }
        let settings = settings()
        #expect(settings.cloudBackup && settings.includeSavedVoicesInBackups)
        #expect(!settings.backupNoticeDismissed && !settings.voiceSetupAnswered)
        let voices = try VoiceLibrary(root: root)
        var old = voices.folder; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try old.setResourceValues(flags)
        let model = BackupModel(settings: settings, root: root)
        try await model.start()
        try voices.save([])
        #expect(try !flag(root))
        #expect(try !flag(voices.folder))
        #expect(try !excluded(voices.folder.appendingPathComponent("voices.json")))
    }

    @Test func cardSurvivesRelaunchAtomicReplacementNewHierarchyAndBothDirections() async throws {
        defer { cleanup() }
        let settings = settings()
        let model = BackupModel(settings: settings, root: root)
        try await model.start()
        let voiceLibrary = try VoiceLibrary(root: root)
        try voiceLibrary.save([])
        let noteFile = root.appendingPathComponent("meeting/nested/data.json")
        try FileManager.default.createDirectory(at: noteFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: noteFile, options: .atomic)
        try await model.update(cloud: false, voices: true, dismissNotice: true)
        #expect(settings.backupNoticeDismissed)
        #expect(try flag(root) && flag(voiceLibrary.folder))
        try Data("replacement".utf8).write(to: noteFile, options: .atomic)
        try voiceLibrary.save([]) // DurableFile's temp + rename path.
        #expect(try excluded(noteFile))
        #expect(try excluded(voiceLibrary.folder.appendingPathComponent("voices.json")))
        let fresh = root.appendingPathComponent("new/hierarchy/audio.caf")
        try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: fresh, options: .atomic)
        #expect(try excluded(fresh))
        let reopened = self.settings()
        #expect(!reopened.cloudBackup && reopened.includeSavedVoicesInBackups && reopened.backupNoticeDismissed)
        try await BackupModel(settings: reopened, root: root).start()
        #expect(try excluded(noteFile))
        try await model.update(cloud: true, voices: true)
        #expect(try !flag(root) && !flag(voiceLibrary.folder))
        #expect(try !excluded(noteFile) && !excluded(fresh))
        try await model.update(cloud: false, voices: true)
        #expect(try excluded(noteFile))
    }

    @Test func voicesSwitchIsIndependentAndPersistsWhileGlobalBackupIsOff() async throws {
        defer { cleanup() }
        let settings = settings()
        let model = BackupModel(settings: settings, root: root)
        try await model.start()
        let voices = try VoiceLibrary(root: root)
        try voices.save([])
        let file = voices.folder.appendingPathComponent("voices.json")
        try await model.update(cloud: true, voices: false)
        #expect(try !flag(root) && flag(voices.folder) && excluded(file))
        try voices.save([])
        #expect(try excluded(file))
        try await model.update(cloud: false, voices: false)
        try await model.update(cloud: true, voices: false)
        #expect(try excluded(file))
        #expect(self.settings().cloudBackup && !self.settings().includeSavedVoicesInBackups)
        try await model.update(cloud: true, voices: true)
        #expect(try !excluded(file))
    }

    @Test func noticeDismissalAndOneQuestionSetupPersistWithoutChangingBackup() {
        defer { cleanup() }
        let settings = settings()
        settings.dismissBackupNotice()
        settings.answerVoiceSetup(enable: false)
        #expect(self.settings().backupNoticeDismissed && self.settings().voiceSetupAnswered)
        #expect(!self.settings().automaticallyNameVoices)
        settings.answerVoiceSetup(enable: true)
        #expect(self.settings().automaticallyNameVoices)
        #expect(self.settings().cloudBackup && self.settings().includeSavedVoicesInBackups)
    }

    @Test func failedStorageChangeDoesNotCommitOrDismiss() async throws {
        defer { cleanup() }
        try Data([0]).write(to: root)
        let settings = settings()
        let model = BackupModel(settings: settings, root: root)
        await #expect(throws: (any Error).self) {
            try await model.update(cloud: false, voices: false, dismissNotice: true)
        }
        #expect(settings.cloudBackup && settings.includeSavedVoicesInBackups && !settings.backupNoticeDismissed)
        #expect(!model.updating)
    }
}
