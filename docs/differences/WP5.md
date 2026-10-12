# WP5 — transcription job: differences from Android

## Pipeline

- **Engine and windows.** Android decodes 28 s windows with Parakeet and a streaming Sortformer diarizer. iOS feeds
  Apple's `SpeechAnalyzer` the file one second at a time from the resume point (`AppleSpeechTranscriber`, pull-based,
  so a long file is never in memory) and the analyzer finds its own segments. A "window" on iOS is one finalized
  result; `JobEvent.windowDone` follows the finalized audio. A final result without words (silence) is reported as an
  empty finalized segment, so long silences still move `doneMs` and the checkpoints on.
- **Reading the file.** A read or conversion error part-way, or an input that stops more than 2 s short of the total,
  fails the words with `OPEN` (Android: `reading { }` maps an `IOException` to `OPEN`) and keeps the last checkpoint;
  it is never saved as a complete transcript. At the end of the file the sample-rate converter is flushed so the last
  frames are heard, and the transcriber reports the whole duration as done before it returns.
- **Download failures.** Apple's asset install errors map to `NO_CONNECTION` (URL connectivity errors) and
  `NOT_ENOUGH_STORAGE` (out of space), else `INSTALL`; the job ends `downloadFailed` with part `SPEECH`. Apple reports
  no "free about N MB" figure, so `requiredFreeBytes` is 0.
- **Speakers come after the words.** FluidAudio's diarization is offline and needs the whole file, so the speaker step
  runs once the words are in the note. The draft has one voice, naming opens after the job, and there are no live
  voice suggestions, draft names, draft merges or `names.json`. A speaker failure leaves every word one voice
  (`speakerAnalysisFailure = SPEAKERS`, "All words shown as one voice"); unlike Android there is no partial
  diarization to keep.
- **Stepper.** Reading, Preparing, Words, Speakers & matching, Saving (Android: Words & voices, then Matching). When the
  speaker step will run, the words fill the bar to 85 % and the speakers from 85 % to 99 %; otherwise the words fill
  it. Identify speakers (no words step) fills the bar with the speaker step alone, and its Processed stat is the
  analysed audio. The percent never goes back and reaches 100 only when the job is done. The headlines are Android's,
  plus "Finding speakers"; "Finding words and speakers" is not used.
- **Time left in the speaker step** is extrapolated from that step's own progress (FluidAudio's fraction). During the
  words it counts the words plus the measured finalization (`processing.finalizationMs`, matching and saving), not the
  speaker step, so the estimate can grow when the speaker step begins.
- **Download progress.** Apple's speech assets report a `Progress` fraction and FluidAudio a fraction; neither reports
  bytes, so `DownloadProgress` carries per-mille counts and `needsConsent` carries 0 missing bytes.
- **Battery.** `UIDevice` reports the level in 5 % steps and gives no charge counter, so a projection appears after
  the level drops one step (and 120 s); the simulator has no reading and the cell is hidden.
- **Low memory** is carried through (`RunningProgress.lowMemory`) but nothing sets it yet; iOS has no OOM to catch.

## Checkpoint

- **Format.** `work/checkpoint.json` is iOS's own (`CheckpointState`, version 1): source file name, `length:mtime`
  signature, language, the finalized segments with their words, `doneMs`, `totalMs`, `elapsedMs`, `inferenceMs`,
  `resumedFromMs` and `wordsComplete`. Android's encoder, diarizer, voice-clip and word-log members do not exist on iOS,
  so `CheckpointData` (base64 floats) and the word log are not ported. A checkpoint that does not match the audio file,
  its signature or the job's language fails with `CHECKPOINT_MISMATCH`; so does one that cannot be read.
- **Writes.** A checkpoint is written to a temporary file, flushed with `fsync`, the previous one is kept as
  `checkpoint.json.bak` and the new one renamed into place; a load falls back to the backup. `checkpointed` is sent only
  after that. A failed write is `SPACE` when the volume reports out of space or has under 64 MB free (Android's
  `writeFailure()`), else `SAVE`. The folder is `NoteStore.directory(for:)` + `work/`, so it goes with the note.
- **When.** Once 30 s more audio is final than the last checkpoint covered, and at most every 10 s of running time
  (a fast decode of a long file would otherwise rewrite a large file all the time), plus at a stop and when the words
  are complete. A process death loses at most one interval.
- **Times.** `elapsedMs` and `inferenceMs` count from the analyzer's first report, so a model download is in neither
  the provenance's `x-inferenceMs` nor the pace a resumed run starts from. On iOS they are the same number: Android
  counts only its inference blocks in `x-inferenceMs`, and Apple's analyzer gives no finer split.
- **Resume** starts the analyzer 1 s before `doneMs` and drops the words that end at or before it; a result that
  straddles `doneMs` keeps its later words and rebuilds its text from them (joined with spaces).
- **Stop** keeps every finalized result: a pause saves the checkpoint at once (results are already final; volatile
  words are dropped). A stop before the first final result leaves no checkpoint ("Paused before any words were
  found"). A stop during the speaker step keeps the complete checkpoint, and the resumed run goes straight to the
  speakers; when the provenance record says those words were saved, it leaves the note's words as they are, edits
  included. A cancel saves nothing; the coordinator discards `work/`.
- **Word body limit.** Checked at each checkpoint with a 40-character speaker id per word (as long as the ids the
  speaker step gives), so the job fails with `LONG` at the checkpoint that passes the limit and keeps the one before.
  The queue then discards that checkpoint, as Android's `clearFailed` does: no new try can use it.

## Ports and model changes (frozen interfaces)

- `TranscriptionEvent.volatile(TranscriptSegment?)` is new: Apple's volatile results for the draft.
- The `Transcribing` contract (documentation only): a transcriber that read its input to the end reports
  `.progress(done: total, total:)` before it returns; one that returns short of the total is treated as a read failure.
- **Provenance** is not in `Note`: WP0's model is unchanged. The latest on-device run's record (`engine:
  apple-speechtranscriber`, `language`, `x-inferenceMs`, `x-resumedFromMs` and, after the speaker step,
  `x-speakerDiarization {backend: fluidaudio, model, sha, turnCount, speakerCount}`) is kept beside the note in
  `<note>/provenance.json` (`ProvenanceRecord`, `ProvenanceFiles`) with a SHA-256 of the words it describes and the
  speaker ids the analysis gave. Android writes it into the sealed document at the end of the job; iOS has no sealed
  document, so **WP12** asks `ProvenanceStoring.provenance(for: note)` at export. That returns nil once the note's
  words are not the run's (another version selected, a passage edited, an import), and leaves the speaker record out
  once the speakers are not the analysis's (a merge keeps it). A speakers-only job adds its speaker record when the
  note still holds the run's words.
- `RunningProgress`, `DraftState`, `JobPhase`, `JobStep` and `ProgressTracker` live in CassiniNotebook (`Progress/`),
  `CheckpointState`, `SpeechWindows`, `TranscriptBudget`, `TranscriptProvenance` and `ProvenanceRecord` in
  `Transcription/`.
- `TranscriptionJob` needs a `TranscriptionJobHost` (settings at the start, and `applySpeakers`, which the app gives to
  `VoicesStore`), a `CheckpointStoring` (`CheckpointFiles(notes:)`) and a `ProvenanceStoring`
  (`ProvenanceFiles(notes:)`). A speakers-only job never reads or removes `work/`.
- `JobProgress` (CassiniEngine) is the one owner of the running job's progress: the card reads `phase(for:)`, the rows
  `processingPhase(for:)` and `fraction(for:)`. WP5 does not write `ProcessingState.running.phase`/`fraction` (WP0).
  The finalization measurement goes to the `onFinalization` given at init. WP4's coordinator should call `begin`,
  `apply` and `end` as `ProcessingStore` does now.
- `ProgressText.timeLeftLine` is the banner's line 2 for **WP9** (Android's `ui_time_left_line_*`): "About 6–9 min
  left", "Under 1 min left", "Calculating time left…".

## Interim queue (until WP4)

`ProcessingStore` now runs `TranscriptionJob`. Contract for **WP4**:

- "Stop and keep progress" pauses the running job; transcribing the note again resumes from its checkpoint, in the
  language the checkpoint has (the Settings language applies only to a note without saved progress).
- `work/` is dropped only by Cancel (`cancel`), by a finished transcription, and on `CHECKPOINT_MISMATCH` or `LONG`,
  after which Transcribe again starts over; Delete permanently removes it with the note's folder. Remove from queue
  (`dequeue`), Stop on a queued note and iOS ending the background time take the note out of the queue and keep its
  checkpoint, as Android's dequeue (paused, user) and system stop do. When iOS ends the background time the running
  job pauses with its checkpoint and the queued notes keep theirs. A speakers-only job never touches `work/`, even when
  cancelled.
- Moving a note to Recently Deleted (`trash`) keeps its progress, as Android's `prepareTrash` does: a running job
  stops as "Stop and keep progress" (pause, user) without a "Paused at…" notice, and a queued note leaves the queue
  with its checkpoint. A restored note resumes when it is transcribed again. Unlike Android, a note that was queued
  is not queued again on restore: the interim queue has no trashed-job record (WP4).
- A pause posts "Paused at 12:30 of 48:13. Pick up where you left off. The draft so far is kept." (Android's paused
  banner, title and body as one notice; an iOS body when the system paused it), or "Paused before any words were
  found. Resume to start transcribing." when there is no checkpoint. `hasSavedProgress(_:)` tells WP4 and WP6 that a
  note has a checkpoint; there is no paused note status yet (WP4), and the read-only checkpoint draft is WP6's.
- "All words shown as one voice" with Transcribe again is **WP9**'s banner, from the fact `speakerAnalysisFailure ==
  .speakers`; until then the Note screen shows that failure's message card.
- A speakers-only job no longer changes the note's language.

## Tests

Ported: `ProgressTrackerTest` (draft names, suggestions and `aRestoredDiarizerKeepsMatchingPossible…` do not apply),
`TranscriptionProgressTest`, `BatteryProjectionTest`, `CheckpointStateTest` and `CheckpointGoldenTest` (adapted to the
iOS members; the golden holds the words of Android's 0.1.0 golden; names, encoder, diarizer, word-log and directory-key
cases do not apply), `TranscriptionJobTest` (with `missingModelsAreInstalledWithConsentAndADownloadFailureFailsTheJob`
against a transcriber that throws the download failure; the document, seal, marker, adopt, live-matching and
native-handle cases do not apply), and `FormatTest#progress` (the card's stats and the banner's line) and `#clock`.

`SpeechWindowsTest` does not apply: its fixed-window, overlap, context, `ceilMs`/`floorMs`, VAD split, decode-policy,
padding and quiet-cut cases all belong to Parakeet's windows, which iOS does not have, so neither that arithmetic nor
its tests are ported. iOS's own `SpeechWindowsTests` cover the parts it runs (block size, resume point, checkpoint
interval). `FileReaderTests` (CassiniInference) cover the reader over generated WAV and CAF files: the resume offset,
the first block's time on the recording clock, block reading, the converter's tail, the end of the file and a
recording cut short.
