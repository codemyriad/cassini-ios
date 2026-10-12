# WP8 — speaker naming, voices, merge, matching: notes for the README and later work packages

## Differences from Android

- **Renaming a saved voice keeps the names already in notes** (Android semantics, user decision). Before WP8 the iOS
  app also renamed every linked speaker in every note. Forget and Forget everyone keep the names too; only the links
  to the voice go.
- **Saved voices keep their samples, not a running mean.** Android stores each person as the running mean of their
  confirmed prints (`VoiceCodec.enrol`/`unenrol`); iOS stores one sample per note and speaker and matches against the
  normalised mean of the usable samples. Unenrol removes exactly the sample it enrolled (the port of
  `VoiceCodecTest#unenrolInvertsTheRunningMean`); a voice left without samples is forgotten everywhere, as on Android.
  Enrolling the same note and speaker again replaces its sample.
- **Thresholds.** iOS uses its own embedding model (FluidAudio), so matching uses automatic 0.85, suggest 0.65, margin
  0.12 (`VoiceThresholds.ios`) and needs 6 s of isolated speech per print and per sample (Android: 0.72/0.50/0.08 and
  4 s). "Likely" needs the suggest threshold; Remember needs 6 s ("Too little speech to remember this voice.").
- **Automatic naming stays opt-in** (Settings, off by default). A suggestion is then "Is this Luca?" and the Remember
  subtitle says "Future notes will suggest Luca" instead of Android's "will name Luca automatically" while the setting
  is off.
- **No draft naming.** iOS identifies speakers after the transcript, with FluidAudio's offline pipeline, so there is
  no naming while a job runs (`DraftNames`, `names.json`, pending prints at adopt). Android's draft cases of
  `SpeakerNamingTest` and `SpeakerStatsTest` have no port. The suggestion card goes above the speaker's first passage.
- **Staleness is per model, not per dimension.** A voice is stale when none of its samples was made with the current
  speaker model (`settings.speakerModelIdentity`, model plus weight fingerprint); before any analysis nothing is
  stale. Android also checks the pinned dimension (512).
- **Files.** `PrivateVoices/voices.json` is `{"version": 1, "voices": [...]}` and still reads the bare array older
  iOS builds wrote. Each note's prints are `PrivateVoices/<note id>.json`, `{"version": 1, "prints": [...]}` (bare
  array read too). Matches live in the note's speakers, not in the print files (Android: `voiceprints/<id>.json`
  version 2 with matches keyed by variant). A newer file is read-only and never written; an unparseable one is renamed
  `<name>.corrupt-<epoch ms>` and the list stays read-only until Forget everyone; a read error is retried on the next
  access. The forget-everyone generation is in the settings (`voices.generation`), not in a file under `voices/`.
- **Merging a confirmed speaker** links the merged speaker to its voice as an automatic match in the new version (the
  confirmation stays with the version it was made in), as Android copies CONFIRMED prints as AUTO.
- **Speakers list.** iOS keeps its Speakers sheet (list of a note's speakers, Add a speaker, Identify speakers, Saved
  voices); Android opens Name a speaker from the transcript only. Tapping a speaker opens the same Name a speaker sheet.
- **Saved voices.** The options menu is a system menu, so its open state is not restored; the open dialog is kept with
  the scene (`@SceneStorage`). When nobody is saved but notes still hold voiceprints, iOS offers "Forget all voice
  data" (kept iOS extension). The read-only banner is drawn by the screen until WP9's banner catalogue takes it over.
- **Copy.** Android's English, with "device" for "phone" ("Remember this voice on this device", "Voiceprints stay on
  this device") because Cassini also runs on iPad.
- **Versions.** Rows read "Version N" with the version's name and date. Opening the sheet no longer saves the current
  transcript as a version; versions are kept where the transcript changes (analysis, merge, transcription, and the
  existing "Previous transcript" when another version is shown).
- **Words in a gap** between turns go to the nearest turn, as on Android (iOS used to leave them without a speaker),
  and a speaker's overlapping turns count once. Without a valid turn the transcript is left as it is and the note
  records `speakerAnalysisFailure = .empty`.

## Where things live (for later work packages)

- **Pure rules** (`Packages/CassiniNotebook/Sources/CassiniNotebook/Speakers/`): `SpeakerAttribution` (stable passage
  ids: a passage of one speaker keeps its id and text; the first piece of a split passage keeps the id, later pieces
  get ids derived from it), `VoiceMatcher`, `NameMatch`, `DefaultLabels`, `SpeakerStats` (also used for
  `Note.speakingTime(for:)`), `VoiceCodec`/`NoteVoiceCodec`, `SpeakerNaming` (the sheet reducer), `NamingCommit` (what
  the effects change, worked out before anything is written), `SpeakerSuggestions`, `SavedVoiceList` and
  `SavedVoicesScreen`, and the note mutators in `Speakers.swift` / `Note+Voices.swift`
  (`applySpeakerAnalysis(turns:matches:voiceNames:autoName:stamp:)`, `rejectVoice`, `unlinkVoice`, `reconcileVoices`,
  `carriedExclusions(for:)`, `mergeSpeaker(_:into:stamp:)`, `apply(_: [SpeakerChange])`). `SpeakerStats` lives here,
  not in `Transcript/` as the plan's layout says, because WP8 owns `SpeakerStatsTest`; WP6 should use it.
- **Files:** `Persistence/VoiceLibrary.swift`; the `VoiceStore` actor (Engine) adds `snapshot()`, `rename`, `forget`,
  `forgetEveryone` (returning `VoiceEdit`), `appendPrints` and `sweepOrphans(keeping:)`.
- **Writes:** `VoicesStore.perform(_:noteID:speakerID:)` writes the note first (one `LibraryStore.commit` of value
  `SpeakerChange`s, safe to rerun) and the voices after; when the voices can't be written the note's links go back.
  A note that can't be saved leaves the voices untouched.
- **Launch:** the `.voiceLinks` startup slot deletes the print files of notes that no longer exist.
- **Seed:** in `--seed speakers` the second speaker is "Speaker 2" with a suggestion of the saved "Sam Rivera", so the
  note shows the suggestion card (used by `SpeakerNamingFlowTests` and the screenshots).
- **For WP6:** `TranscriptList(suggestion:)` now gets `SuggestionCard`s from `NoteDetailView`. Making each turn's
  speaker label a button that opens `NameSpeakerSheet` (and the "auto" badge on the label) is left to WP6, which owns
  `TurnView`; the sheet only needs `NameSpeakerSheet(noteID:speakerID:)`. A passage edit should keep a version through
  `saveCurrentVersion` in its own mutator.
- **For WP7:** the sample plays through `PlaybackStore.playSample(_:from:duration:)`; swap in `playRange` when it
  exists.
