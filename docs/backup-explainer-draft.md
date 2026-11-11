# Moving and backup: draft wording (not final)

Settings, Moving and backup, and its Learn more page explain how the user's own iOS backups treat Cassini's data. This
is option A of the backup and device migration decision document (2026-11-11): explain today's behaviour and change
nothing. Nothing that is excluded from backup changes: notes stay in Application Support, and `PrivateVoices` and the
model folder keep `isExcludedFromBackup`. That decision is still open.

All copy is **draft**. It comes from the decision document's "Draft wording, iOS" section and still has to go through
Alex and the shared catalog (codemyriad/cassini-ux `strings/strings.json`). Until then it lives in
`Cassini/Features/Settings/BackupDraftCopy.swift` as plain English shown with `Text(verbatim:)`. It stays out of the
string catalogs on purpose: `scripts/check-strings.sh` requires all five translations, and draft wording must not get
invented ones. Before this ships, each entry below moves to the `Settings` table, vendored with its translations
(docs/shared-strings-pin.md), and `BackupDraftCopy.swift` goes away.

## Proposed catalog entries

Platform `ios`, milestone and status to be set by the coordinator (`draft` until approved).

| Proposed id | Role | English (draft) |
| --- | --- | --- |
| `ios.settings.backup.heading` | section-heading | Moving and backup |
| `ios.settings.backup.body` | description | Your notes are included in your iPhone backups and when you move to a new iPhone. iOS decides where those backups go, based on your own settings. |
| `ios.settings.backup.learnMore` | button | Learn more |
| `ios.backup.title` | title | Moving and backup |
| `ios.backup.icloud.heading` | section-heading | iCloud Backup |
| `ios.backup.icloud` | body | If iCloud Backup is on, your notes are stored in your iCloud account. |
| `ios.backup.icloud.private` | body | Apple can read an iCloud backup unless you turn on Advanced Data Protection in your Apple Account settings. |
| `ios.backup.icloud.leaveOut` | body | To leave Cassini out of iCloud Backup, open Settings, your name, iCloud, Storage, Backups, this iPhone, and turn Cassini off. |
| `ios.backup.computer.heading` | section-heading | Backups on a computer |
| `ios.backup.computer` | body | A backup made on your computer is readable by anyone who can use that computer unless you set a backup password. |
| `ios.backup.savedVoices.heading` | section-heading | Saved voices and models |
| `ios.backup.savedVoices.stay` | body | Saved voices stay on this iPhone only. On a new iPhone you will need to name speakers again. |
| `ios.backup.models` | body | Speech models are not moved; your new iPhone downloads them again. |
| `ios.backup.copyHeading` | section-heading | A copy you keep yourself |
| `settings.transfer.exportHint` (reuse: add `ios` to its platforms) | description | To keep a copy somewhere safe, use Export All as ZIP. |

## Open points for the wording

- **iPad.** Cassini runs on iPad too. "iPhone" in the body, the leave-out path and the saved-voices line needs an iPad
  variant, or neutral wording ("this device").
- **The Settings path** in `ios.backup.icloud.leaveOut` is the decision document's. It must be checked on iOS 18 and
  iOS 26, whose labels differ ("Storage" against "Manage Account Storage").
- **Saved voices.** The line describes today's behaviour (excluded from backup). If option B is chosen after the
  two-iPhone test, it becomes "Saved voices, which let Cassini recognise people you have named, move with your notes."
- **An existing claim.** The On-device models footer says "Transcription runs on this device. Audio never leaves it."
  With backups that is not strictly true (Android replaced its equivalent with `android.privacy.processing`,
  "Transcription runs on this phone."). This draft leaves the translated string unchanged; the shared catalog should
  decide its iOS replacement.
- **What it must not claim** (decision document): end-to-end encryption, that a backup happened, or that turning
  anything off deletes an existing backup. The draft makes none of these claims.
