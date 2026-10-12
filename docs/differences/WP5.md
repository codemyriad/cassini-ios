# WP5 — transcription job: differences from Android

## Pipeline

- **Engine and windows.** Android decodes 28 s windows with Parakeet and a streaming Sortformer diarizer. iOS feeds
  Apple's `SpeechAnalyzer` the file one second at a time from the resume point (`AppleSpeechTranscriber`, pull-based,
  so a long file is never in memory) and the analyzer finds its own segments. A "window" on iOS is one finalized
  result; `JobEvent.windowDone` follows the finalized audio.
- **Speakers come after the words.** FluidAudio's diarization is offline and needs the whole file, so the speaker step
  runs once the words are in the note. The draft has one voice, naming opens after the job, and there are no live
  voice suggestions, draft names, draft merges or `names.json`. A speaker failure leaves every word one voice
  (`speakerAnalysisFailure = SPEAKERS`, "All words shown as one voice"); unlike Android there is no partial
  diarization to keep.
- **Stepper.** Reading, Preparing, Words, Speakers & matching, Saving (Android: Words & voices, then Matching). When the
  speaker step will run, the words fill the bar to 85 % and the speakers from 85 % to 99 %; otherwise the words fill
  it. The percent never goes back and reaches 100 only when the job is done. The headlines are Android's, plus
  "Finding speakers"; "Finding words and speakers" is not used.
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
  after that.
- **When.** Once 30 s more audio is final than the last checkpoint covered, and at most every 10 s of running time
  (a fast decode of a long file would otherwise rewrite a large file all the time), plus at a stop and when the words
  are complete. A process death loses at most one interval.
- **Resume** starts the analyzer 1 s before `doneMs` and drops the words that end at or before it; a result that
  straddles `doneMs` keeps its later words and rebuilds its text from them (joined with spaces).
- **Stop** keeps every finalized result: a pause saves the checkpoint at once (results are already final; volatile
  words are dropped). A stop before the first final result leaves no checkpoint ("Paused before any words were
  found"). A stop during the speaker step keeps the complete checkpoint, and the resumed run goes straight to the
  speakers. A cancel saves nothing; the coordinator discards `work/`.
- **Word body limit.** Checked at each checkpoint with a 40-character speaker id per word (as long as the ids the
  speaker step gives), so the job fails with `LONG` at the checkpoint that passes the limit and keeps the one before.

## Ports and model changes (frozen interfaces)

- `TranscriptionEvent.volatile(TranscriptSegment?)` is new: Apple's volatile results for the draft.
- `Note.provenance` (`TranscriptProvenance`, optional, schema 2 unchanged) is new: the latest on-device run's record
  for exports, `engine: apple-speechtranscriber`, `language`, `x-inferenceMs`, `x-resumedFromMs` and, after the speaker
  step, `x-speakerDiarization {backend: fluidaudio, model, sha, turnCount, speakerCount}`. Android writes this into
  the sealed document at the end of the job; iOS keeps it with the note and WP12 writes it at export.
- `RunningProgress`, `DraftState`, `JobPhase`, `JobStep` and `ProgressTracker` live in CassiniNotebook (`Progress/`),
  `CheckpointState`, `SpeechWindows`, `TranscriptBudget` and `TranscriptProvenance` in `Transcription/`.
- `TranscriptionJob` needs a `TranscriptionJobHost` (settings at the start, and `applySpeakers`, which the app gives to
  `VoicesStore`) and a `CheckpointStoring` (`CheckpointFiles`). `JobProgress` (CassiniEngine) drives the tracker once a
  second for the screens; WP4's coordinator should call `begin`, `apply` and `end` as `ProcessingStore` does now.

## Interim queue (until WP4)

`ProcessingStore` now runs `TranscriptionJob`. "Stop and keep progress" pauses the job; transcribing the note again
resumes from its checkpoint. Cancel and Remove from queue drop the work. When iOS ends the background time the job is
paused with its checkpoint (it used to be cancelled and lose everything). A speakers-only job no longer changes the
note's language.

## Tests

Ported: `ProgressTrackerTest` (draft names, suggestions and `aRestoredDiarizerKeepsMatchingPossible…` do not apply),
`TranscriptionProgressTest`, `BatteryProjectionTest`, `CheckpointStateTest` and `CheckpointGoldenTest` (adapted to the
iOS members; the golden holds the words of Android's 0.1.0 golden; names, encoder, diarizer, word-log and directory-key
cases do not apply), `SpeechWindowsTest` (the fixed-window, clock and context arithmetic; the VAD split, decode-policy,
padding and quiet-cut cases belong to Parakeet's decoder and do not apply), `TranscriptionJobTest` (the document,
seal, marker, adopt, live-matching and native-handle cases do not apply), and `FormatTest#progress`/`#clock` for the
card's words.
