import Foundation
import Observation
import CassiniNotebook

/// Directory flags cover every descendant, including a new inode from an atomic replacement.
/// No recursive scan is needed when the user flips a switch. All filesystem work runs on an actor.
public actor BackupStorage {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func apply(cloud: Bool, voices: Bool) throws {
        let privateVoices = root.appendingPathComponent("PrivateVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: privateVoices, withIntermediateDirectories: true)
        // Set the more restrictive child first before opening the parent to backup.
        try Self.setExcluded(!cloud || !voices, at: privateVoices)
        try Self.setExcluded(!cloud, at: root)
    }

    private static func setExcluded(_ excluded: Bool, at location: URL) throws {
        var url = location
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }
}

@MainActor @Observable public final class BackupModel {
    private let settings: SettingsStore
    private let storage: BackupStorage
    private let library: LibraryStore?
    public private(set) var updating = false
    public private(set) var ready = false

    public init(settings: SettingsStore, root: URL, library: LibraryStore? = nil) {
        self.settings = settings
        self.storage = BackupStorage(root: root)
        self.library = library
    }

    public func start() async throws {
        try await update(cloud: settings.cloudBackup, voices: settings.includeSavedVoicesInBackups)
        ready = true
    }

    public func update(cloud: Bool, voices: Bool, dismissNotice: Bool = false) async throws {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let previous = (settings.cloudBackup, settings.includeSavedVoicesInBackups)
        do {
            try await storage.apply(cloud: cloud, voices: voices)
        } catch {
            // Keep the committed preference on an I/O failure; startup retries it as well.
            try? await storage.apply(cloud: previous.0, voices: previous.1)
            throw error
        }
        settings.commitBackup(cloud: cloud, voices: voices)
        library?.setCloudBackup(cloud)
        if dismissNotice { settings.dismissBackupNotice() }
    }
}
