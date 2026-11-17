/// Backup eligibility, never evidence that the system has enabled or completed a backup.
public struct BackupPresentation: Equatable, Sendable {
    public let meetingsIncluded: Bool
    public let voicesIncluded: Bool

    public init(cloud: Bool, voices: Bool) {
        meetingsIncluded = cloud
        voicesIncluded = cloud && voices
    }

    /// Imports count as saved meetings too. Live and interrupted captures do not;
    /// neither does a library containing only meetings in Recently Deleted.
    public func showsNotice(notes: [Note], loaded: Bool, ready: Bool, dismissed: Bool) -> Bool {
        loaded && ready && meetingsIncluded && !dismissed && notes.contains(where: ArchiveSelection.isExportable)
    }
}
