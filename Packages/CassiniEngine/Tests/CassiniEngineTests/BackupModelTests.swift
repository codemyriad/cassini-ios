import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor @Suite(.serialized) struct BackupModelTests {
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
            value.removeAllCachedResourceValues()
            if try value.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true { return true }
            value.deleteLastPathComponent()
        }
        return false
    }
    func flag(_ url: URL) throws -> Bool {
        var value = URL(fileURLWithPath: url.path)
        value.removeAllCachedResourceValues()
        return try value.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    // macOS can briefly report the preceding backup flag after setResourceValues returns, even on a
    // newly constructed URL with its resource cache cleared. Wait for the filesystem observation,
    // rather than assuming an actor hop also synchronises the OS backup metadata. Never retry writes.
    func expectFilesystem(_ condition: () throws -> Bool,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // The full gate runs package tests beside Xcode compilation; allow the same 30-second
        // observation window as the other package polling helpers, without retrying any writes.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var satisfied = try condition()
        while !satisfied, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            satisfied = try condition()
        }
        #expect(satisfied, "Filesystem did not reach the expected backup flags", sourceLocation: sourceLocation)
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
        try await expectFilesystem { try !flag(root) }
        try await expectFilesystem { try !flag(voices.folder) }
        try await expectFilesystem { try !excluded(voices.folder.appendingPathComponent("voices.json")) }
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
        try await expectFilesystem { try flag(root) && flag(voiceLibrary.folder) }
        try Data("replacement".utf8).write(to: noteFile, options: .atomic)
        try voiceLibrary.save([]) // DurableFile's temp + rename path.
        try await expectFilesystem { try excluded(noteFile) }
        try await expectFilesystem { try excluded(voiceLibrary.folder.appendingPathComponent("voices.json")) }
        let fresh = root.appendingPathComponent("new/hierarchy/audio.caf")
        try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: fresh, options: .atomic)
        try await expectFilesystem { try excluded(fresh) }
        let reopened = self.settings()
        #expect(!reopened.cloudBackup && reopened.includeSavedVoicesInBackups && reopened.backupNoticeDismissed)
        try await BackupModel(settings: reopened, root: root).start()
        try await expectFilesystem { try excluded(noteFile) }
        try await model.update(cloud: true, voices: true)
        try await expectFilesystem { try !flag(root) && !flag(voiceLibrary.folder) }
        try await expectFilesystem { try !excluded(noteFile) && !excluded(fresh) }
        try await model.update(cloud: false, voices: true)
        try await expectFilesystem { try excluded(noteFile) }
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
        try await expectFilesystem { try !flag(root) && flag(voices.folder) && excluded(file) }
        try voices.save([])
        try await expectFilesystem { try excluded(file) }
        try await model.update(cloud: false, voices: false)
        try await model.update(cloud: true, voices: false)
        try await expectFilesystem { try excluded(file) }
        #expect(self.settings().cloudBackup && !self.settings().includeSavedVoicesInBackups)
        try await model.update(cloud: true, voices: true)
        try await expectFilesystem { try !excluded(file) }
    }

    @Test func repeatedBackupChangesReachBothDirectoryFlags() async throws {
        defer { cleanup() }
        let model = BackupModel(settings: settings(), root: root)
        try await model.start()
        let voices = root.appendingPathComponent("PrivateVoices", isDirectory: true)
        // Three complete cycles of all four (cloud, voices) states, without flooding coreservicesd.
        for step in 0..<12 {
            let cloud = step % 2 == 0, includeVoices = step % 4 < 2
            try await model.update(cloud: cloud, voices: includeVoices)
            try await expectFilesystem {
                try flag(root) == !cloud && flag(voices) == (!cloud || !includeVoices)
            }
        }
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
