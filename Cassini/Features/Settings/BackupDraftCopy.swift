import Foundation

/// DRAFT WORDING, NOT FINAL (backup-and-device-migration decision document, iOS option A). Placeholder English for the
/// "Moving and backup" explanation, waiting for Alex's copy and the shared catalog (codemyriad/cassini-ux
/// `strings/strings.json`). Each constant names the catalog id it is proposed under; docs/backup-explainer-draft.md
/// lists them.
///
/// These are deliberately plain strings shown with `Text(verbatim:)`, outside the string catalogs: the catalogs require
/// all five translations, and draft wording must not get invented ones. Before this ships, every constant moves to a
/// `Settings` catalog entry vendored from the shared catalog (docs/shared-strings-pin.md), and this file is deleted.
enum BackupDraftCopy {
    /// `ios.settings.backup.heading`: Settings section header.
    static let heading = "Moving and backup"
    /// `ios.settings.backup.body`: the section's one explanation.
    static let body = "Your notes are included in your iPhone backups and when you move to a new iPhone. "
        + "iOS decides where those backups go, based on your own settings."
    /// `ios.settings.backup.learnMore`: the row that opens the page below.
    static let learnMore = "Learn more"

    /// `ios.backup.title`: the page's title.
    static let title = "Moving and backup"
    /// `ios.backup.icloud.heading`
    static let icloudHeading = "iCloud Backup"
    /// `ios.backup.icloud`
    static let icloud = "If iCloud Backup is on, your notes are stored in your iCloud account."
    /// `ios.backup.icloud.private`
    static let icloudPrivate = "Apple can read an iCloud backup unless you turn on Advanced Data Protection in your "
        + "Apple Account settings."
    /// `ios.backup.icloud.leaveOut`: the path must be checked on iOS 18 and iOS 26 before it ships.
    static let icloudLeaveOut = "To leave Cassini out of iCloud Backup, open Settings, your name, iCloud, Storage, "
        + "Backups, this iPhone, and turn Cassini off."
    /// `ios.backup.computer.heading`
    static let computerHeading = "Backups on a computer"
    /// `ios.backup.computer`
    static let computer = "A backup made on your computer is readable by anyone who can use that computer unless you "
        + "set a backup password."
    /// `ios.backup.savedVoices.heading`
    static let savedVoicesHeading = "Saved voices and models"
    /// `ios.backup.savedVoices.stay`: today's behaviour (the voices folder is excluded from backup).
    static let savedVoicesStay = "Saved voices stay on this iPhone only. On a new iPhone you will need to name "
        + "speakers again."
    /// `ios.backup.models`
    static let models = "Speech models are not moved; your new iPhone downloads them again."
    /// `ios.backup.copyHeading`
    static let copyHeading = "A copy you keep yourself"
    /// Proposed reuse of `settings.transfer.exportHint` (today Android only), whose quoted action must equal
    /// `export.zip.all` without its ellipsis.
    static let exportHint = "To keep a copy somewhere safe, use Export All as ZIP."
}
