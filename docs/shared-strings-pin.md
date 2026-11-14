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
