# Shared string source

The current global shared catalog pin (updated in D-1131 / L-65) is `codemyriad/cassini-ux`
`d9bf213a30179c395657e8d8ecd34fe2b987af1a`, `strings/strings.json`, SHA-256
`fedf8cfa51992ded96fafb5d4f15af7e5d1700f877575b51caf0f5da6ad970fa`.
`contracts/shared-strings/UPSTREAM.json` is the global source pin and points to the complete, byte-identical catalog in
`Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges/strings/strings.json`; `contracts/wave5-strings/UPSTREAM.json`
and the resource bundle pin use the same commit and hash. The generators reject disagreement between them.

`scripts/generate-status-badge-strings.py` emits the implemented badge and provenance selection: the ten existing shared badge /
interrupted-position keys and the seven `states.phone.*` labels (`audioOnly`, `cantPlay`, `cantReadTranscript`,
`couldntTranscribe`, `newerFormat`, `pausedAt`, `queued`), plus the two L-10 header subtitle templates. All six translations and named placeholders remain
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
immutable commit without local edits. The states contract remains v3; L-10 adopts the `Imported` label with model kind `received`.
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

D-1029 adds `common.tryAgain` to the generated Library selection. D-1052 advances the shared pin to include the
current catalog and keeps all implemented import-card labels. `scripts/import-contract.py --update <cassini-ux checkout>`
vendors `contract/import-types.json` from that checkout’s immutable `origin/main` and records its SHA-256 in
`contracts/import-types/UPSTREAM.json`. It also generates the Open-with UTI list. `check-strings.sh` verifies both.
D-1029 requires an actual Ogg Opus header for `.opus` / `.ogg`, tightening the earlier Android-compatible rule that
allowed arbitrary decodable audio under `.opus`. iOS continues to decode MP3, M4A, native FLAC and PCM/float WAV using AVFoundation.

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
The `status-badges` bundle now uses the global D-1034 pin above, adopting `Imported`.
The shared source was updated first in cassini-ux #44; its complete catalog is vendored without edits.

L-10 also compiles `format.previewSubtitle.received` and `format.previewSubtitle.importedOtherDevice` into the StatusBadge catalog. Library and Search derive provenance from stored import origins; recovered local recordings remain own. Imported transcript versions identify files transcribed on another device, including after local edits or re-transcription. Import-flow catalogs and strings are unchanged.

D-1042 adds the shared Library All/Starred and Search filter IDs to `generate-library-strings.py`,
including the shared date wording and starred empty state, using the same immutable catalog and vectors.

D-1038 repins the global catalog and its complete status/format/library resource bundle to cassini-ux
`b26190b57d8e35391ba9b4bafd177d66b10f0ec3` (`origin/main`, 14 November 2026).
`scripts/generate-export-strings.py` compiles the implemented Phase 2 export labels, descriptions, title,
format-group accessibility label, More formats and audio-only note into `ExportPhase2.xcstrings` for all six locales.
Existing generated subsets are regenerated from the new global pin. The export resource bundle carries every
file present in upstream `vectors/export/`, byte-identical with SHA-256 receipts in its `UPSTREAM.json`.
That commit contains Markdown vectors and audio-size vectors, but no plain-text/SRT/WebVTT goldens;
local regression tests cover those PARITY §2 rules without claiming shared-vector conformance.

Wave 6 (`D-979`, supersedes #120) shares the Wave 5 source pin
`b26190b57d8e35391ba9b4bafd177d66b10f0ec3` (SHA-256
`10d65abc7b10f81422377632aa899506b33e02cc9269afc96e11ec89cee69367`). The full byte-identical catalog is in
`contracts/wave5-strings/strings.json`. `generate-wave6-strings.py` selects iOS backup and voice wording,
with all six translations verbatim in `Wave6.xcstrings`; Android-only exclusion claims are deliberately omitted.
The global catalog and generated Phase 2 subsets retain the current main-branch pins described above.

D-1052 pins the native FLAC import contract (v2026-11-14.3) to the same immutable source as the complete
shared catalog above. Native FLAC is validated before import and again before decoding or transcription.

D-1101 / D105 advances the complete shared catalogs to cassini-ux
`277c65423909ec6f696836eeefede6d4ac5e4c84` (#55), SHA-256
`a735381a6c7cbe8b1d4bd57cc4ac811d99939036b2e457b120fe19cdb7a7bc4b`.
All existing generated subsets are regenerated. LibraryWave5 now selects the iPhone/iPad hero subtitles,
first-run privacy sentences and iCloud settings line; SettingsPhase2 selects `firstRun.howTo.phone`.
The superseded subtitle and qualifier leave the compiled app. Settings retains all four D98 privacy variants,
with “Transcribed” replacing “Written down”. The native string audit finds no process wording using “write down”.
Only implemented IDs are compiled: pending `permissionPrompt.*` / L-68 on D-1095 stays out of the app,
and Info.plist and InfoPlist.xcstrings are unchanged. The status/format/library bundle is re-vendored as a whole;
the coordinated import policy is verified byte-identical and the Markdown selection keeps its source receipt.

D-1131 (D110, L-65) advances the complete shared catalogs (`contracts/shared-strings/UPSTREAM.json`,
`contracts/wave5-strings/UPSTREAM.json`, `contracts/import-types/UPSTREAM.json`,
`Packages/CassiniNotebook/Tests/CassiniNotebookTests/Resources/status-badges/UPSTREAM.json`, and the Markdown selection's
`source_commit`) to `codemyriad/cassini-ux` `d9bf213a30179c395657e8d8ecd34fe2b987af1a` (SHA-256
`fedf8cfa51992ded96fafb5d4f15af7e5d1700f877575b51caf0f5da6ad970fa`), adding the "Report a problem" copy in Settings › About
and regenerating all compiled subsets across all six languages.
