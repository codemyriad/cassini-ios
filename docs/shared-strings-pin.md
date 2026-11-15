# Shared string source

WP1 pins the full shared catalog to `codemyriad/cassini-ux`
`5e0c34e0f1bb390298dabdf4eedc494e933fd329`, `strings/strings.json`, SHA-256
`4bbe42b47bbf2e6e61ed15b1c54cabf4096e92aca63b9ed84d428070baa52acf`.
`contracts/shared-strings/UPSTREAM.json` is the global source pin and points to the complete, byte-identical catalog in
`Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges/strings/strings.json`; the resource
bundle pin uses the same commit and hash. The generator rejects disagreement between them.

`scripts/generate-status-badge-strings.py` emits only the implemented WP1 selection: the ten existing shared badge /
interrupted-position keys and the seven `states.phone.*` labels (`audioOnly`, `cantPlay`, `cantReadTranscript`,
`couldntTranscribe`, `newerFormat`, `pausedAt`, `queued`). All six translations and named placeholders remain
verbatim. The generated catalog is `Cassini/Resources/Strings/StatusBadge.xcstrings`, with literal lookup call sites
only in `Cassini/Strings/StatusBadgeStrings.swift`. App language bundle selection remains in the existing
`StatusBadgeCopy` adapter.

`scripts/generate-meeting-strings.py` emits the implemented Phase 1 meeting selection from the same pinned catalog into
`Cassini/Resources/Strings/MeetingPhase1.xcstrings` and `Cassini/Strings/MeetingPhase1Copy.swift`: WP3 chrome
(`library.allMeetings`, `library.backToAllMeetings`, `meeting.find.placeholder`) and WP5 transcribing status, details,
draft heading and compact speaker-match copy (`common.stop`, `transcribing.heading`, `transcribing.eta.minutes`,
`transcribing.details.a11y`, `transcribing.stopAndKeepProgress`, `transcribing.transcriptSoFar`,
`transcribing.step.{reading,preparing,words,speakers,saving}`,
`transcribing.stat.{timeLeft,audioDone,audioDoneValue,wordsSoFar,batteryAtFinish}`,
`transcribing.speakerSuggestion`, `transcribing.speakerSuggestion.{no,yes}`). Named placeholders stay verbatim and the
remaining catalog entries are not shipped before their implementation milestone.

The complete existing states, format and library vector resources and their expected rows are repinned from the same
immutable commit without local edits. The states contract remains v3 with `Received`; WP1 does not implement WP7.
HARMONY is read at the immutable source commit, not copied into an unused local snapshot.

The pins below document earlier implemented string subsets. They are historical source receipts, not the WP1 source
for the generated status table.

D14 Search date-filter and D95 unknown-date group copy are vendored from `codemyriad/cassini-ux` at `484c6048447381e04fd1d1133e7ae02c6c6d5e58`,
`strings/strings.json` (SHA-256 `2b672fc8a88e62d704e6e2b5a4ed8d999a8aa77e90b8c006e7c7c0e43d26e169`).
Entries: `search.filter.anyDate`, `search.filter.date.today`, `search.filter.date.week`,
`search.filter.date.month`, `library.group.unknownDate`. Today reuses the existing Library translation; all values match the shared catalog.
No shared catalog or contract was edited.

`Library.xcstrings` uses the English source key `Date unknown` for the shared
`library.group.unknownDate` entry. Its six values are byte-identical to that source entry:
English `Date unknown`, Italian `Data sconosciuta`, French `Date inconnue`, Spanish `Fecha desconocida`,
Brazilian Portuguese and European Portuguese `Data desconhecida`. The source entry is a plain heading,
without count placeholders or plural transformations.

D96 bulk transfer copy is pinned to cassini-ux `4d577376f6360ed352fa75307f4dc47890ed9858`,
`strings/strings.json` (SHA-256 `7b059577a6e4a5d692ccb5c745916bc790e9e0fe7c77c5572fb64fda80f0f7b3`).
`BulkTransfer.xcstrings` vendors `import.*`, `export.zip.*`, `common.cancel` and `common.done`, with all six locales
and the catalog plural forms. Placeholder names map to positional integer format arguments. D14 values above remain
unchanged; no shared source was edited.

D50.2/D50.3 Markdown export copy and S-5 vectors are pinned to cassini-ux `7cdb069fb0b71953feeeb7a6805c63835f968540`.
The selected Markdown entries remain byte-identical to Android's selected catalog; the full source catalog SHA-256
is `8b20048485bd928d2067806284c381ffb8033768ecf084387600517d0006690f`. Per-file hashes and selected ids are recorded in
`Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/markdown/UPSTREAM.json`. No shared source was edited.

The Whistle fallback notice (#117) is vendored from cassini-ux `7cdb069fb0b71953feeeb7a6805c63835f968540`,
`strings/strings.json` (SHA-256 `8b20048485bd928d2067806284c381ffb8033768ecf084387600517d0006690f`): entry
`models.parakeetUltra.noteFallback`, in `Notices.xcstrings` with all six locales, every value as in the catalog.
The entries above stay at their pins; no shared source was edited.

D-1029 adds `common.tryAgain` to the generated Library selection; the current shared pin already includes every
import-card label, so the strings pin does not change. `scripts/import-contract.py --update <cassini-ux checkout>`
vendors `contract/import-types.json` from that checkout’s immutable `origin/main` and records its SHA-256 in
`contracts/import-types/UPSTREAM.json`. It also generates the Open-with UTI list. `check-strings.sh` verifies both.
D-1029 requires an actual Ogg Opus header for `.opus` / `.ogg`, tightening the earlier Android-compatible rule that
allowed arbitrary decodable audio under `.opus`. iOS continues to decode MP3, M4A and PCM/float WAV using AVFoundation.

Wave 5 first-run hero and backup-gated privacy copy (`D-974`, `L-27`, `D98`) is pinned to `codemyriad/cassini-ux`
`b26190b57d8e35391ba9b4bafd177d66b10f0ec3`, `strings/strings.json` (SHA-256
`10d65abc7b10f81422377632aa899506b33e02cc9269afc96e11ec89cee69367`), vendored byte-identically in
`contracts/wave5-strings/strings.json` alongside `contracts/wave5-strings/UPSTREAM.json`.
`scripts/generate-wave5-strings.py` compiles the eight iOS Wave 5 IDs (`firstRun.hero.title`, `firstRun.hero.subtitle`,
`firstRun.hero.phoneBackupQualifier`, `firstRun.hero.subtitlePhoneNote`, `privacy.onDevice.{iphone,ipad}.{withBackup,backupExcluded}`)
into `Cassini/Resources/Strings/LibraryWave5.xcstrings` and `Cassini/Strings/LibraryWave5Copy.swift`, and the four Phase 2
Saved voices IDs (`D-1047`, `L-67`: `savedVoices.howToAdd`, `savedVoices.row.meetingCount`, `savedVoices.row.meta`,
`savedVoices.row.stale`) into `Cassini/Resources/Strings/SavedVoicesPhase2.xcstrings` and
`Cassini/Strings/SavedVoicesPhase2Copy.swift` across all six locales. It also synchronises the 18 Phase 2 entries
in Settings, Speakers, Trash and Failures from their shared IDs, retaining native lookup keys and compiling
named placeholders to native format arguments.
These include all 11 iOS additions from cassini-ux #44 and six existing phone entries now declared for iOS.
The generator verifies the immutable catalog hash and rejects missing entries, locale/placeholder drift and
changes to the compiled Phase 2 values. No Phase 2 translation is maintained locally.
The Phase 1 `status-badges` bundle stays at
`5e0c34e0f1bb390298dabdf4eedc494e933fd329` until `L-10` (`D-997`) migrates `Received` to `Imported`.
The shared source was updated first in cassini-ux #44; its complete catalog is vendored without edits.
