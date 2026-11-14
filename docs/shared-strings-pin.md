# Shared string source

D-1042 repins the full shared catalog to `codemyriad/cassini-ux`
`b26190b57d8e35391ba9b4bafd177d66b10f0ec3`, `strings/strings.json`, SHA-256
`10d65abc7b10f81422377632aa899506b33e02cc9269afc96e11ec89cee69367`.
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
immutable commit without local edits. The states contract remains v3; `received` remains its internal kind and the new catalog calls it `Imported`.
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

Wave 5 first-run hero and backup-gated privacy copy (`D-974`, `L-27`, `D98`) is pinned to `codemyriad/cassini-ux`
`31973ff9784fcc66c1c7993b903a336e8f2c1432`, `strings/strings.json` (SHA-256
`c634cdfbcf961391e1f3a084c4d8ac07aa10946a289ecba4da8ec1ebc25717ca`), vendored byte-identically in
`contracts/wave5-strings/strings.json` alongside `contracts/wave5-strings/UPSTREAM.json`.
`scripts/generate-wave5-strings.py` compiles the eight iOS Wave 5 IDs (`firstRun.hero.title`, `firstRun.hero.subtitle`,
`firstRun.hero.phoneBackupQualifier`, `firstRun.hero.subtitlePhoneNote`, `privacy.onDevice.{iphone,ipad}.{withBackup,backupExcluded}`)
into `Cassini/Resources/Strings/LibraryWave5.xcstrings` and `Cassini/Strings/LibraryWave5Copy.swift` across all six
locales. The Phase 1 `status-badges` bundle was subsequently repinned for D-1042 to `b26190b57d8e35391ba9b4bafd177d66b10f0ec3` with the full catalog and contract vectors. No shared source was edited.

D-1042 adds the shared Library All/Starred and Search filter IDs to `generate-library-strings.py`,
including the shared date wording and starred empty state.
