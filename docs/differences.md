# Differences from Android

Cassini for iOS is a port of [Cassini for Android](https://github.com/codemyriad/cassini-android/tree/rebuild)
(branch `rebuild`). It keeps Android's behaviour and copy and ports its tests (each marked `// ports:
<AndroidTest>#<name>`). Where the two disagree, Android's behaviour wins, unless the difference is an iOS-only extra or
a platform constraint. This page lists every difference that remains and the reason for it. The
[README](../README.md#differences-from-android) has a summary.

The sections follow the areas of the app: engines and thresholds, the storage model, recording, transcription, the
iOS extras and the platform. [Android tests without an iOS port](#android-tests-without-an-ios-port) lists the tests
that were not ported, with the reason for each.

## Engines and thresholds

### Speech recognition

- **Engine.** Android runs Parakeet over 28 s windows, with a streaming Sortformer diarizer. iOS gives the file to
  Apple's `SpeechAnalyzer` / `SpeechTranscriber` one second at a time from the resume point
  (`AppleSpeechTranscriber`). The reader pulls the audio, so a long file is never all in memory, and the analyzer finds
  its own segments. On iOS a "window" is one finalized result, and `JobEvent.windowDone` follows the finalized audio.
  A final result without words (silence) counts as an empty finalized segment, so long silences still advance
  `doneMs` and the checkpoints. Android's `SpeechWindowsTest` arithmetic (fixed windows, overlap, VAD split, padding)
  belongs to Parakeet, so it is not ported. iOS's `SpeechWindowsTests` cover what iOS runs: the block size, the resume
  point and the checkpoint interval.
- **Speech language.** Apple's models are per language, so iOS asks for a speech language in Settings ("· Installed"
  marks the ones on the device). Android recognises any language on its own. A language that Apple does not offer
  counts as nothing to download, and the job fails with `UNSUPPORTED_LANGUAGE` rather than waiting for a consent that
  cannot help. `UNSUPPORTED_LANGUAGE` and `RESERVATION_LIMIT` (Apple's speech assets) are failure codes that exist only
  on iOS.
- **Speech model size.** iOS does not report the size of Apple's speech assets before they are downloaded. Settings
  shows "Managed by iOS" instead of a size, and "Not available" when Apple has no model for the language or the
  device. The model download screen lists the missing parts without sizes. Its free-space check and the "Needs about N
  free" figure use an estimate per part: 512 MiB for the speech model (`ModelPlan.speechInstallBytes`) and the pinned
  files plus 32 MiB for the speaker models. DL_NO_SPACE quotes the plan's figure. When there is no figure, its body
  reads "Free some space and try again." and never "0 MB".
- **Download progress.** Apple's assets and FluidAudio both report only a fraction, not bytes. `DownloadProgress`
  therefore carries per-mille counts, and the download banner has no byte counts. Apple install errors map to
  `NO_CONNECTION` (URL connectivity errors), `NOT_ENOUGH_STORAGE` (out of space) or `INSTALL`. Apple gives no
  "free about N MB" figure for its own downloads.

### Speaker analysis

- **Pipeline.** Android uses Sortformer and CAM++. iOS uses FluidAudio's offline pyannote community-1 segmentation,
  WeSpeaker embeddings and VBx clustering on Core ML (`SpeakerAnalyzer`, CassiniInference). This pipeline needs the
  whole file, so it runs after the words are saved in the note. As a result there are no live speakers in the draft,
  no draft naming (`DraftNames`, `names.json`), no live voice suggestions and no draft merges. The draft has one voice,
  and naming opens after the job. When the speaker step fails, every word stays in one voice
  (`speakerAnalysisFailure = SPEAKERS`, "All words shown as one voice"). Unlike Android, there is no partial
  diarization to keep. A step that finds nobody shows the iOS notice "No speakers were detected".
- **Words in a gap** between turns go to the nearest turn, as on Android. A speaker's overlapping turns count once.
  Without a valid turn the transcript stays as it is, and the note records `speakerAnalysisFailure = .empty`.
- **Voiceprints are not compatible.** Android's CAM++ voiceprints and iOS's WeSpeaker embeddings come from different
  models, and neither app imports the other's.
- **Matching thresholds.** These come from iOS's own embedding model: automatic naming at 0.85, suggestions at 0.65,
  and a 0.12 margin over the next candidate (`VoiceThresholds.ios`). Each print and each sample needs 6 s of isolated
  speech. Android uses 0.72, 0.50 and 0.08, with 4 s. "Likely" needs the suggestion threshold. Remember needs 6 s
  ("Too little speech to remember this voice."). The thresholds have not been calibrated on a representative iPhone
  corpus.
- **Automatic naming is opt-in.** Settings has "Name strong matches automatically", off by default. While it is off, a
  suggestion reads "Is this Luca?", and the Remember subtitle says "Future notes will suggest Luca" instead of Android's
  "will name Luca automatically".
- **Staleness is per model.** A saved voice is stale when none of its samples came from the current speaker model
  (`settings.speakerModelIdentity`: the model plus a fingerprint of its weights). Before any analysis, nothing is
  stale. Android also checks the pinned dimension (512).
- **Speaker model install.** The install fetches the revision that FluidAudio pins, using FluidAudio's
  `ModelHub.download`. Each file is checked against the checked-in `SpeakerModelManifest.diarizer` (21 files, with
  size and SHA-256) and the `.fluidaudio-revision` marker. A mismatch is `FILE_CHECK_FAILED`, and the folder is removed
  for the next try. Before a download, only what FluidAudio would wrongly keep is removed: files with the wrong size or
  hash, or the whole folder when its marker names another revision. FluidAudio's `.partial` files stay, so an
  interrupted install resumes.
- **One install, joined.** `SpeakerAnalyzer` never answers "busy". An analysis that arrives during another one waits
  its turn, and every request made during an install joins that install (`SpeakerModelInstaller`).
- **FluidAudio's offline switch** (`ModelHub.offlineMode`) is process-wide. `ModelNetworkGate` keeps it on. It turns
  it off only while at least one permitted download is running, and it counts those downloads, so a request that joins
  or ends never turns the switch back on during another download. Analyses load the models with the switch on, so a
  damaged file fails the load instead of being downloaded again without consent.
- **Redirects.** FluidAudio builds its own `URLSession`s and exposes no session delegate, so Cassini cannot restrict
  redirects. `RedirectPolicyTest` has no port. Integrity rests on the pinned revision and the hash check of every file.
  `Privacy.txt` lists the hosts the downloads normally use.
- **Offline errors.** iOS has no reachability check. URL Loading already reports an offline device as
  `notConnectedToInternet` (or `timedOut`, `cannotFindHost`, `dataNotAllowed`), and these map to `NO_CONNECTION`.
  `networkConnectionLost` and HTTP errors map to `INTERRUPTED`.
- **Best effort.** As on Android, the speaker models are a best-effort part of a transcription. If they fail to
  download, the words are still saved, in one voice. A speakers-only job has nothing else to do, so it ends with
  `JobFailure.download(x)` (part `.speakers`) or asks for consent.

### Memory

- iOS ends an app that runs out of memory without an error that Cassini can catch, so there is no TX_MEMORY banner.
  At the start of a job, `MemoryPreflight` compares the recording's 16 kHz samples, plus 30 % headroom, with
  `os_proc_available_memory()`, as Android's `Limits.memoryAllows` does, and sets the card's low-memory hint. The hint
  says "iPad" on an iPad. A pause for memory shows as an ordinary pause. A `MEMORY` failure reads "Couldn't transcribe"
  with its message.
- `UIDevice` reports the battery level only in 5 % steps and has no charge counter. The "Battery at finish" projection
  therefore appears after the level drops one step (and 120 s). The simulator has no reading, and the cell is hidden
  there.

## Storage model

### Notes are `note.json`, not documents

- Android transcribes into a sealed Cassini document (`document.opus`) and keeps a Room catalogue. iOS keeps each note
  as `<root>/<id>/note.json` (title, transcript passages with word times, speakers, versions, bookmarks, status,
  playback position, waveform), next to its audio. The portable Cassini document is written only at export. A note
  with a transcript, or one transcribed to no words, counts as a readable document for the status table, unless it was
  imported from a document that Cassini could not read or that is newer.
- **Passages, not one word list.** iOS notes keep passages (`TranscriptSegment`) with optional word times. Android
  keeps one word list with a speaker per word. The screen flattens the shown version's passages into words. A passage
  without word times (an edited one) counts as one word of its whole text, so it plays and highlights as one piece.
  Character ranges count Swift characters, not UTF-16 units.
- **Passages without a speaker** show as "Unknown speaker" in amber, and their header is not a button. In exports
  they get the id `unassigned`, the id the sealed document uses. Android's words always have a speaker.
- **No FTS4.** Search uses `LibraryIndex`, an in-memory index with each note's tokens folded for case and accents. It
  is built at the first search and kept until the note changes. `SearchText.snippet` follows SQLite's `snippet()`
  window choice. The tests that probe SQLite have nothing to test.
- **Computed previews.** Android stores `preview` and rewrites it with the body. iOS computes the row preview from the
  transcript shown, at the saved playback position (`PreviewText`). It reads the stored `previewText` only for a note
  without a transcript.
- **Version kinds.** Transcript versions store a kind (`transcription`, `mergedSpeakers`, `editedPassages`, …), and
  the screen names it in the reader's language. For builds before the change, each version also stores its English
  `name`. An unknown kind written by a newer build is kept, written back, and shown as "From a newer Cassini". Android's
  variants carry no display name.
- **Speaker placeholders.** Notes store "Speaker N" (or "Voce N" from an Italian build), as Android does. Every screen
  names them in the reader's language.
- **Durable writes.** `note.json`, `jobs.json`, the voice files, the provenance record and the checkpoints are all
  written through `DurableFile`. It writes `<name>.tmp`, flushes it with `F_FULLFSYNC`, renames it over the target and
  then flushes the directory, as Android's `NoteFiles` does.
- **Settings** are kept in `UserDefaults` under Android's DataStore key names (`models.consentAt`, `queue.hold`,
  `notices.recoveredAck`, …, see `SettingsKeys`), with timestamps in epoch milliseconds. The queue hold is stored as
  `user` or `system`. The forget-everyone generation is the setting `voices.generation`.

### The queue

- Android keeps the queue in Room's `jobs` table. iOS keeps it in `<root>/jobs.json` (`{version, jobs}` in `seq`
  order). Every transition is one atomic write, made before the call returns. A failed write leaves the queue in memory
  as it was, so a claim that cannot be saved leaves the job queued for the next drain.
- A `jobs.json` from a newer Cassini is kept as it is, and the queue takes no writes in that run: Transcribe is refused
  with `queueUnavailable`. An unreadable one is moved to `jobs.json.unreadable-<date>`, and the queue starts empty.
  Either way no `work/` is deleted at launch, and notes that said they were queued are set back with `INTERRUPTED`.
- The job is the truth. The coordinator keeps each note's coarse `status` in step with it, for older readers. There is
  no sealed output, marker or adopt step (`ADOPT_PENDING`), because the transcript is written to `note.json`
  atomically.

### Checkpoints

- `work/checkpoint.json` uses iOS's own format (`CheckpointState`, version 1). It holds the source file name, a
  `length:mtime` signature, the language, the finalized segments with their words, `doneMs`, `totalMs`, `elapsedMs`,
  `inferenceMs`, `resumedFromMs` and `wordsComplete`. Android's encoder, diarizer, voice-clip and word-log members do
  not exist on iOS. A checkpoint that cannot be read, or that does not match the audio, its signature or the language,
  fails with `CHECKPOINT_MISMATCH`, and its `work/` is kept until Start over, as on Android.
- Each write keeps the previous checkpoint as `checkpoint.json.bak`, and a load falls back to it. A failed write is
  `SPACE` when the volume is full or has under 64 MB free, else `SAVE`.
- **When.** A checkpoint is written once 30 s more audio is final than the last one covered, and at most every 10 s of
  running time. It is also written at a stop and when the words are complete. A process death loses at most one
  interval.
- **Times.** `elapsedMs` and `inferenceMs` count from the analyzer's first report, so a model download counts in
  neither. On iOS they are the same number, because Apple's analyzer gives no finer split.
- **Resume** starts the analyzer 1 s before `doneMs` and drops the words that end at or before it. A stop during the
  speaker step keeps the complete checkpoint, and the resumed run goes straight to the speakers.
- **Word body limit.** The limit is checked at each checkpoint, counting a 40-character speaker id per word. The job
  fails with `LONG` at the checkpoint that passes the limit and keeps the one before it.

### Provenance

- Android writes the run record into the sealed document at the end of a job. iOS has no sealed document. It keeps the
  latest on-device run's record beside the note, in `<note>/provenance.json`, together with a SHA-256 of the words it
  describes. The words' members are recorded when the words are saved, the speaker members when the speaker step has
  put its speakers into the note.
- An export writes this record into each variant whose words are still the run's (`ExportProvenance`). Otherwise the
  variant gets `{engine: cassini-ios, kind: user-edited}`. A version made by a merge also gets `x-speakerMerges`,
  `x-speakerAssignmentEditedBy` and `x-derivedFromTranscript`, as Android's merged variant does.
- **Keys.** The record has Android's keys (`JobProvenance`, `SpeakerAttribution.record`) with iOS's values;
  `ProvenanceGoldenTests` pins the key sets and JSON types against Android's:
  - The processing step: `backend` "Apple Speech framework (SpeechAnalyzer, on-device)", `engine`
    `apple-speechtranscriber`, `model` "Apple SpeechTranscriber <locale>" (the locale whose assets ran), `device` the
    hardware model and OS ("iPhone17,1, iOS 26.0.1 (23A355)"; Android writes "Android CPU"), `source` "recording" as on
    Android, and `version` "Speech framework of <OS and build>". Apple names no speech model version or revision, so
    the OS build stands in for it; there is no `model revision` as in Android's `version`.
  - `x-inferenceMs`, `x-resumedFromMs`, and `x-segmentation`, which describes what iOS runs: the whole file streamed
    to the analyzer in 1 s blocks, the analyzer finding its own segments, and a resume 1 s before the checkpoint.
  - `x-speakerDiarization`: `backend` (FluidAudio at its pinned commit, offline diarizer on Core ML), `model`
    (`pyannote-community-1-wespeaker-coreml-v1`), `modelRevision` (the pinned FluidInference revision),
    `modelSha256`, `elapsedMs` (the analysis without the model install), `turnCount`, `speakerCount`, `assignment`
    (Android's string: `SpeakerAttribution.assign` follows the same rule; a passage without word times counts as one
    word) and `sourceSeparation: false`. `modelSha256` is the fingerprint the voiceprints carry: a SHA-256 over the
    embedding, filterbank and PLDA models' `model.mil` and `weight.bin` with their paths, not the digest of one
    weights file as on Android, because iOS's diarizer is a bundle of four Core ML models. Records of earlier builds
    stored it as `sha`, which still reads.
  - `x-speakerIdentification`, counts only: `model`, `sha256`, `dim` (the print length), `metric: cosine`, the iOS
    thresholds as `autoThreshold`, `suggestThreshold` and `margin`, `speakersWithPrints`, `autoApplied` (speakers the
    analysis named from a saved voice) and `suggested` (speakers only offered one). With automatic naming off, a strong
    match is offered, so it counts as suggested. Document info's "N names from saved voices" reads `autoApplied`, as
    on Android.
  - A re-attribution (Identify speakers again over a version that already had speakers) also writes
    `x-derivedFromTranscript`, the variant it started from, and, when that variant is one of a verified imported
    document's, that document's `provenance.attribution` as `x-sourceAttribution`, as Android's
    `SpeakerAttribution.record` does. A first analysis is sealed into its transcription, so it has neither.
- **Not applicable on iOS.** `x-speakerDiarization.threshold`, `minDurationOn` and `minDurationOff` are Sortformer's
  post-processing parameters, and `x-incrementalDiarization` describes Sortformer's streaming windows and speaker
  cache. FluidAudio's offline pipeline has neither, so iOS leaves the four keys out instead of writing values that
  would mean something else.
- **Older records.** A `provenance.json` written before these members existed still reads and exports. The export
  leaves out what that build did not record (the processing step, `x-segmentation`, `elapsedMs`, `modelRevision`,
  `assignment`, `sourceSeparation` and `x-speakerIdentification`) rather than guessing it, so Document info shows no
  names from saved voices for such a note.
- **One speaker record.** Only the latest speaker analysis's record is kept. A version of an earlier analysis keeps the
  words' members and loses `x-speakerDiarization` and `x-speakerIdentification` once a later analysis replaces them.

### Saved voices

- **Samples, not a running mean.** Android stores each person as the running mean of their confirmed prints. iOS
  stores one sample per note and speaker, and matches against the normalised mean of the usable samples. Unenrol
  removes exactly the sample it enrolled. A voice left without samples is forgotten everywhere, as on Android.
- **Files.** `PrivateVoices/voices.json` is `{"version": 1, "voices": [...]}`. Each note's prints are
  `PrivateVoices/<note id>.json`. Matches are kept in the note's speakers, not in the print files (Android:
  `voiceprints/<id>.json` with matches keyed by variant). A newer file is read-only. An unparseable one is renamed
  `<name>.corrupt-<epoch ms>`, and the list stays read-only until Forget everyone. `PrivateVoices` is excluded from
  backups.
- **Merging a confirmed speaker** links the merged speaker to its voice as an automatic match in the new version, as
  Android copies CONFIRMED prints as AUTO.
- **Names carry over** on Transcribe again and Identify speakers again through note-local voices, as on Android. The
  note's named, unrejected speakers with a print become candidates for the next analysis. An automatic match to one
  restores the name whatever the automatic-naming switch says, and links no saved voice.

### Deleting

- Android removes the catalogue row and the files. On iOS the note's directory is the row, because `note.json` is
  inside it. A permanent delete stops and awaits the note's job, then removes its voiceprints, then renames the
  directory to `<id>.purging` (one atomic step) and removes it. A delete that is cut short therefore never leaves audio
  without its `note.json` for the launch to rebuild into a note.
- Claims are kept by the main-actor `TrashService`, not a note lock. Restore refuses a note that is being deleted, and
  a failed delete gives the note back.

### The format layer (CassiniCore)

The format layer follows [cassini-format](https://github.com/codemyriad/cassini-format)'s SPEC.md wherever Android is
stricter or looser than the spec.

- **Verification gate.** Verification is blocked only when `CASSINI_AUDIO_OPUS_SHA256` disagrees ("the manifest
  wins"). Any other stale copy is a warning, so conformance vectors 007 and 017 read as `ok` on iOS and `unverified` on
  Android, and they import as `ok`. A `stale-audio` document says why (`audio-digest-mismatch`,
  `audio-shape-mismatch`).
- **TITLE follows the manifest on every seal.** The first TITLE is set to `meeting.title`, and repeats are dropped.
  Android writes TITLE only on a fresh seal that has none.
- **A fresh seal drops every `CASSINI_*` tag of the source** and keeps only foreign comments. Android keeps old
  `CASSINI_TX_*` chunk sets.
- **Comments are decoded one at a time.** A foreign comment that is not UTF-8 is skipped with a warning and written
  back byte for byte. Android rejects the whole file.
- **Every copy of the manifest is rebuilt on write.** A file that reads back with a `tag-manifest-disagreement` is
  never shipped.
- **Compact word bodies.** About 150,000 words (some 16 hours) fit, against Android's 110,000.
  `WordBodyBudget.fitsHeader` checks the room left before a seal.
- **Byte-exact strings.** JSON and tag values compare by UTF-8 bytes, as Java's do. Swift's `==` would treat
  canonically equivalent strings as equal.
- **Smaller rules.** A transcript with another media type is readable, with a warning. An OpusHead or OpusTags packet
  over 8 MiB is invalid metadata. An I/O error while reading the headers is `unreadable`.

### Import

- **WAV.** iOS hands every container except Ogg Opus to AVFoundation, which also decodes 24-bit and float WAV. There
  is therefore no "Unsupported WAV" failure and no IMPORT_WAV banner.
- **Sniffing.** AVFoundation reports no MIME type, so the stored name comes from the container signature in the first
  64 bytes (`ImportClassifier`). A display name's extension still wins, as on Android.
- **Opus playback.** iOS cannot play Ogg Opus directly. An imported plain Opus file or Cassini document is decoded once
  to `playback.caf`, which the note plays. The imported file is kept as it was and is what an export seals. A document
  whose audio does not decode stays a document note with unplayable audio, so its transcript still shows.
- **Document cache.** A document is verified once at import, and what was read is stored in `note.json`
  (`DocumentInfo`). The file is never read again to open the note. When the default transcript does not decode, the
  first variant that does becomes the note's transcript.
- **Opening the note.** As on Android, a file picked in the Library is only added to the list. A file opened from
  another app opens its note, or the note that already has those bytes. The picker takes several files at once.
- **Size and placeholders.** The size the provider reports (an iCloud placeholder reports its logical size) is
  checked against the 4 GiB cap and the free space before the coordinated read that downloads it.
- **Imports during launch** are held, with "Importing <name>…" showing, until the launch work has read the notes.
- **Concurrency.** Imports run side by side. The duplicate check and the note write are one step on the `NoteStore`
  actor, so four imports of one file at once add one note.

### Export

- **Same writers, same bytes.** TXT, SRT and WebVTT are ports of Android's `:core` export package. `ExportGoldenTests`
  checks them byte for byte against Android's goldens.
- **Where the words come from.** iOS exports the note's transcript, not a sealed document. A passage edited by hand
  has no word times. Its words share the passage's span in proportion to their length, so the usual cue rules apply.
- **The TXT subtitle line** joins the locale's date and time with Android's pattern: in en_US it reads "Oct 8, 2026,
  3:10 PM · 23:50 · 3 speakers".
- **Share sheet instead of a picker.** Each export is written to `tmp/Exports/<uuid>/<name>` and removed once the
  share sheet closes. "Share original audio" shares a copy named after the note's title, as Android's Save a copy
  names it. The launch sweep removes `tmp/Exports` and stale `*.tmp` files, as Android's `DocumentRepository.sweep`
  does.
- **Portable export.** Audio without an Ogg Opus original is encoded with libopus and mixed down to mono. An export
  that would not fit the 16 MiB word body or the 8 MiB OpusTags packet is refused before it is written. A note
  imported from a stale, unverified or unknown-format document gets a fresh seal over the same audio. The imported
  file itself is never changed.

## Recording

- **Format.** iOS captures 48 kHz 16-bit mono linear PCM into `capture.caf` (96,000 B/s) and compresses it to
  `audio.m4a` at Finish. Android captures Opus or AAC. The format chip reads "PCM 48 kHz". If compression fails, the
  CAF stays the recording, the notice REC_COMPRESSION_FAILED ("Saved in its original quality") shows, and the CAF is
  transcribed.
- **No file-size limit.** CAF has 64-bit chunk sizes and no MP4 index, so Android's 1 GiB AAC limit,
  `FileLimitNear`, `StoppedAtFileLimit` and REC_STOPPED_FILE_LIMIT do not exist.
- **The storage floor counts the finish.** Recording stops just below 200 MiB **plus** the room the M4A copy needs
  (`RecordingPolicy.finishReserve`, 16,000 B per second captured). The hint "Space for about N h more." and the
  15-minute warning count both. Android's floor is 200 MiB alone, because its capture file is the final file.
- **Background.** iOS keeps a recording alive with the `audio` background mode. There is no wake lock.
- **The audio session does not mix.** A call interrupts the recording, which pauses with "Paused — another app is
  using audio" and stays paused until the user resumes. When Resume fails because the other app still holds the audio,
  the recording stays paused.
- **Input lost** (REC_INPUT_LOST, iOS only): unplugging headphones or an external microphone pauses with "Paused —
  audio input disconnected". A media services reset ends the recording as a microphone failure, saving what was
  written.
- **Termination.** On `willTerminate` the recorder stops synchronously, so the CAF header is written. The note is not
  sealed there, because a synchronous handler cannot wait for the note writes already queued. The next launch's
  recovery seals it, so a recording ended by swiping Cassini away is reported as recovered.
- **Finish** seals the note and opens it at once. The waveform, the compression and the hand-off to transcription
  follow while the note is on screen. To keep the user's consent through a kill during compression, a note to
  transcribe is sealed as `queued`. While the audio compresses, the note shows "Waiting to transcribe" with Cancel.
  Android hands off inside `end()` and reports `AUDIO_ONLY` when the hand-off is refused. On iOS the note's status
  shows the result.
- **A seal that cannot be written** leaves the note live on disk. It is shown sealed (`LibraryStore.showUnsaved`),
  written beneath the note's next successful write, and made plain by the next launch's recovery if no write
  succeeds.
- **The screen** is a full-screen cover, shown from the Record button, the Library's card, the Live Activity and an
  automatic stop. It is not restored with the scene. An automatic stop while the screen is minimised brings it back
  with its banner. Android shows such a stop in its ongoing notification.
- **Permissions.** iOS asks for the microphone with the system question. A denial shows "Microphone access is off"
  with Open settings. Notification permission is asked once, at the first recording, after the microphone. Android
  asks for both together on API 33 and later.
- **Live Activity instead of an ongoing notification.** The Lock Screen and the Dynamic Island show the title, the
  running time, the paused state and the storage warning, with Pause, Resume and Finish buttons (`LiveActivityIntent`s
  in `CassiniShared`). A tap opens `cassini://recording`. Every recording activity except the current one is ended at
  launch and at each start. Each button carries its note id, so a leftover activity cannot control another recording.
- **Recovery.** At launch, interrupted notes get their CAF `data` chunk repaired (`CAFRepair`) instead of Android's
  Ogg repair. A note directory with audio but a missing or undecodable `note.json` becomes "Recovered recording 8 Oct",
  and the damaged file is kept as `note.json.corrupt-<ms>`. This replaces Android's catalogue rebuild.
- **Titles** read "Voice note 8 Oct, 08:14", as on Android.
- A recording longer than 36 h is saved with `failure = LONG` and never queued, as on Android.

## Transcription

- **Background time.** Android runs the drain in a foreground service with an ongoing notification. iOS holds one
  `BGContinuedProcessingTask` for the whole drain (`app.codemyriad.cassini.transcription.queue`). It is asked for at
  the drain's first claim, from the screen. The system shows "Transcribing “title”" with the job's progress and a Stop
  button, and each next job only changes the title. iOS grants this request only while Cassini is on the screen. A
  drain that starts in the background, or a refused request, falls back to the finite time of
  `beginBackgroundTask`.
- **When iOS takes the time back.** Expiry and the system's Stop do what Android's `onTimeout` does. The job's stop is
  signalled before iOS's expiration handler returns, the queue is held (`system`), and the job shows as paused by the
  system. While Cassini is hidden, the notification "Transcription paused by iOS · iOS needed the time back. Open
  Cassini to resume." is posted. Only the hold is stored before the handler returns. If iOS kills Cassini first, the
  next launch finishes the pause (`Reconcile`, `ReconcileReport.pausedBySystem`). The notification carries no "Paused
  at" numbers, because the stop reaches the queue before its last progress is saved. The banner copy reads "iOS ended
  the time Cassini had in the background. Resume to continue where it stopped."
- **On the screen.** Cassini counts as hidden only in `.background`. `.inactive` (Control Center, the app switcher, a
  system alert) still counts as visible.
- **The queue runs on the main actor.** `TranscriptionCoordinator` is a `@MainActor @Observable` class. Android's queue
  `Mutex` becomes a serial main-actor section. The job runs off the main actor, and its events reach one ordered
  consumer.
- **Enqueue refusals.** Android's `NO_NOTE`, `TRASHED`, `RECORDING` and `UNKNOWN_FORMAT`, plus two that exist only on
  iOS: `unplayable` (iOS cannot decode the audio) and `queueUnavailable` (see [The queue](#the-queue)). Android only
  logs a refused Transcribe. The iOS note screen says why.
- **Consent** is the recorded `models.consentAt`, or nothing to download, as on Android. Speakers-only jobs use the
  separate speaker-model consent. Consent is given only on the model download screen.
- **The model download screen** says "Transcribe on this device", because Cassini also runs on iPad. Back closes it.
  Notifications are asked for once, during the download step. The standalone Download installs every part that is not
  ready, one after another (`ModelInstalls`). Settings shows a running standalone install as DL_DOWNLOADING with
  Cancel, because the screen closes once the download starts.
- **Cancel during a job's download** stops the job and puts the note back to its state from before, as Android's
  `cancelDownload()` with `Cancel.RESTORE` does. A job that is waiting on Apple's speech assets is not ended by it:
  iOS has no shared owner of that install, and AssetInventory shares the download itself.
- **The stepper** reads Reading, Preparing, Words, Speakers & matching, Saving (Android: Words & voices, then
  Matching). When the speaker step will run, the words fill the bar to 85 % and the speakers fill it from 85 % to 99 %.
  The headlines are Android's, plus "Finding speakers". During the words, the time left counts the words plus the
  measured finalization. The speaker step extrapolates from its own progress.
- **Read-only gate.** Any job row, except one waiting for consent, makes the transcript read-only, as on Android. iOS
  has no draft naming, so Android's SAVING reason and the draft's renamable headers do not exist. While the gate is
  closed, the suggestion cards are hidden, and every sheet of the Note screen follows it through `NoteScreenModel`: the
  Speakers list's speakers and Add a speaker are disabled, Identify speakers waits, Edit passage is locked, and an open
  Name a speaker sheet saves nothing.
- **The progress card's footnote** reads "Transcription runs on this device. If iOS stops it in the background, your
  progress is kept." in place of Android's "Keeps going if you leave the app…" and its "Notifications are off, so
  progress shows only here." variant. iOS shows a running drain's progress in its own continued-processing UI whatever
  the notification permission is, and may end that time (see "When iOS takes the time back" above), so neither of
  Android's lines holds.
- **The draft** shows Apple's volatile results as words that may still change. It follows its end as on Android: the
  header and the progress card stay fixed above it while 160 pt are left for the draft.
- **Recently Deleted.** A queued job of a note moved to Recently Deleted is removed from the queue right after the
  trash, in the queue's serial section, not in the same transaction. The launch repair finishes a trash that Cassini
  closed in the middle of.

## iOS extras

These features exist only on iOS. They were kept by decision.

- **Stars** and the All / Starred filter, with its own empty state ("Keep your favorites close.").
- **Bookmarks** ("Mark a moment" while recording, a bookmark button in the player). Their labels are searched too, and
  an unlabelled one reads "Moment at 01:05".
- **Playback speed** (0.75–2×), kept for the next file.
- **Lock-screen and headphone controls** (`MPRemoteCommandCenter`: play, pause, ±10 s, scrubbing), with Now Playing
  metadata and playback that continues in the background. Going to the background saves the position without
  pausing.
- **Edit passage.** Saving changes the text and drops that passage's word times, but keeps its audio range. A run of
  edits keeps one "Edited passages" version. The first edit keeps the transcript from before it. The editor is locked
  while a job runs.
- **JSON export** of the note, with voice links and exclusions removed.
- **The Speakers list** (the note's speakers, Add a speaker, Identify speakers, Saved voices). Android opens Name a
  speaker from the transcript only. The speaker count in the chips row opens this list. A transcription and its
  speakers are one version, as on Android; Identify speakers on a transcript that has speakers already adds a version
  with the new ones, so the earlier attribution stays available. While a job is pending for the note, the list's
  speakers and Add a speaker are disabled, as the transcript's read-only rule asks.
- **"Recently Deleted"** instead of "Trash", as in Photos and Notes. The rest of the copy is Android's, and the Italian
  is "Eliminati di recente".
- **Forget all voice data** in Saved voices. It is offered when nobody is saved but notes still hold voiceprints, and
  also for a damaged list, so there is always a way back.
- **Settings sections** for Transcription (the speech language, and "Transcribe after recording or import", on by
  default), Speakers (identify speakers, name strong matches automatically) and Your library (counts and duration).
  Turning automatic transcription off makes every finish and import audio only.
- **Notices that exist only on iOS:** REC_INPUT_LOST, REC_COMPRESSION_FAILED, NOTES_UNREADABLE ("2 notes can't be
  read"), "No speakers were detected" and "This audio can't be played" (a playback error at run time).
- **Document info** adds "Made by" (an imported document's vendor). Its model row names Apple's speech model.

## Platform

### Navigation and screens

- **Split view.** Settings, Recently Deleted, Saved voices, Licenses and the model download are pushed routes, as on
  Android. On a regular width (iPad, or a large iPhone in landscape), the Library is a sidebar and the note opens
  beside it (`NavigationSplitView`), its row marked as selected. The detail column's first screen has no back button,
  since the Library it came from is beside it (`ScreenStack.selectedNoteID`, `hidesBackButton`). On a compact width it
  is one stack.
- **Back.** iOS has no system Back. The navigation bar's back button is titled after the screen below
  (`ScreenStack.below`), for example "Back to library", and VoiceOver reads that title. Back-to-clear and the other
  system-back tests do not apply.
- **State restoration.** The stack, the Library's search and Starred filter, the Note screen's search, its open sheet
  (with the text typed in Rename and Name a speaker) and its open question, and the dialogs of the Library, Recently
  Deleted and Saved voices are all kept with the scene. Android keeps them with `SavedStateHandle` and
  `rememberSaveable`. iOS restores a sheet only while what it was about still exists and still allows it. A system
  menu's open state is not restored.
- **Sheets and alerts.** Rename is a sheet with "Enter a title." under the field, because an iOS alert's text field
  takes no inline error. The Library and the Note screen share one Rename sheet and one rule. The confirmation "Stop
  transcription and move to Recently Deleted?" is presented from the root, so both screens share it.
- **The actions sheet** is a context menu (long press) with the same rows. Export is a submenu: the transcript
  formats (disabled, with the reason, without a transcript), Export Cassini document and Share original audio (Android's
  Save a copy rows), the audio always offered. The Note screen's menu has the same rows, and both show Transcribe
  again's "Adds version N. Speaker names carry over.". Its button is labelled "Share and more", as on Android.
- **Rename of a saved voice** is the same sheet as a note's Rename: 80 characters, "Enter a name." under the field, and
  Save only for a changed name, where Android uses its rename dialog.
- **Versions** rows read Android's "Transcribed 8 Oct, 15:40 · 4,812 words" and "Speakers merged · from version 1 ·
  8 Oct, 16:02". A version kind Android does not have (Edited passages, Previous transcript, …) shows its name, its date
  and its word count. No language is added: iOS versions do not record one.
- **The Undo snackbar** stays 10 s, and 30 s while VoiceOver runs. iOS has no recommended-timeout setting. The message
  is also announced, and Undo is both a button and an action of the message.
- **Header.** The iOS wordmark and the serif headline stay. The headline reads "Notes" at accessibility text sizes.

### Language and copy

- **App language.** iOS sets an app's language in the Settings app, so the row shows the current language and opens
  Cassini's page there. Android has a Phone / English / Italiano control.
- **Copy.** Android's English is used, with "device" for "phone" ("Remember this voice on this device", "Transcribe on
  this device", "Voiceprints stay on this device"), because Cassini also runs on iPad. Dates have Android's forms
  (`DateLabels`): "Monday 5 Oct" in the Library and on the Note screen, "Deleted 2 Oct", "8 Oct, 9:41 AM", the year
  only for another year; the time of day follows the locale's 12- or 24-hour clock.
- **Failure copy.** Each stored failure code reads as Android's `error_*`, with iOS's own limits and names (LONG: about
  16 hours of speech, Share original audio). Some codes say something else because the platform differs: OPEN
  (Android asks to choose the file again, because its access to a picked file can lapse; iOS copies an import, so the
  message names the formats it reads), SAVE (Android saves through a file picker, so it asks for another location; iOS
  shares a file it made), SPACE (Android's is about room for a model; iOS's is about the device's storage), AUDIO and WAV
  (the formats AVFoundation reads), MODEL (Apple's speech model can be missing for the device, not only not downloaded)
  and SPEAKERS (Android's says no turns were found; iOS's says the step did not finish and the transcript is saved).
  INTERRUPTED, UNSUPPORTED_LANGUAGE, RESERVATION_LIMIT and CHECKPOINT_MISMATCH exist only on iOS.
- **No NO_ENCODER banner.** libopus is built into Cassini (`CassiniAudio`), so the encoder is always there.
- **String check.** Android lint fails on missing translations. iOS has `scripts/check-strings.sh`, which runs in
  `scripts/test.sh fast`. It fails on an Italian value that is missing, new, `needs_review` or empty, on a plural that
  lacks its `one`, `many` and `other` forms, on placeholders that differ from the English, on stale or missing keys,
  and on literals outside any table.

### Notifications and deep links

- Results are posted only while Cassini is in the background, silently. Each replaces the note's earlier one, as on
  Android's results channel. With previews hidden, the Lock Screen shows "A note was transcribed" and never the title.
  "Paused by iOS" and "Transcription stopped" carry Resume.
- There are no ongoing notifications. The recording uses a Live Activity, and a drain uses the system's
  continued-processing progress.
- Notification permission is asked once (`NoticeCenter.askNotificationsOnce`, for every path): at the first
  recording, the first Transcribe from a screen, or the model download, and only while it is not decided.
  NOTIFICATIONS_OFF means denied. Before the first question, nothing counts as off.
- `cassini://note/<id>` and `cassini://recording` go through `DeepLinks.parse`. Android's `ACTION_VIEW` import is
  iOS's `onOpenURL` of a file.

### Look and accessibility

- **Palette.** The warm iOS palette (paper, card, ink, muted, ember) stays the brand, with tone tints and speaker tints
  added. Fonts are the system's, with Dynamic Type. `ContrastTests` follows Android's `ContrastTest`. It checks every
  pair a screen draws in light and dark (4.5:1 for text, 3:1 for large text and non-text), with tone tints composited
  over the surface under them.
- **Wide windows.** One `ReadableWidth.content` of 560 pt, Android's `MaxContentWidth`, applies to every screen. On
  iPad the Library is the split view's sidebar, which is narrower than the cap. There the search field's placeholder,
  Android's "Search titles and what was said", would wrap, so the field shows the longest of it, "Search titles and
  transcripts" and "Search" that fits on one line (also at large text sizes, where Android keeps the long one).
- **Accessibility audits.** Android runs the Accessibility Test Framework. iOS runs `performAccessibilityAudit()` on
  the same screens plus Recently Deleted and Saved voices, and checks for clipping at the AX5 text size in place of
  `LargeFontScaleTest`. The audit's pixel contrast check is not used, because its verdict changes from run to run on
  Liquid Glass. The tokens are checked instead. The six screens are audited on the iPad as well, beside the Library's
  sidebar. Each issue the audits let pass has its reason in `AuditFilter`: the system's status bar and keyboard, the
  two-line row title and preview, iPadOS's window resize handle, and element detection's unattributed reading of the
  transcript's inverted active word. Element detection runs in an audit of its own, before the other checks: in the
  same audit it could read the screen while the clipping check's text sizes were still being redrawn, and report
  text without an element.
- **Capped bars.** The player and the capture bar stop growing at AX1 and offer the Large Content Viewer. When Import
  and Record do not fit side by side, Import becomes a round icon, as on Android.
- **Transcript paragraphs** are one plain-text element each for VoiceOver and Voice Control. The word links are for
  taps only.
- **The active word** is drawn inverted with the text's background, not with a rounded rectangle.

### Playback

- **Skip interval** is 10 s, as on Android, for the bar, the lock screen and VoiceOver's slider steps.
- `AVAudioPlayer` opens a file synchronously, so an open cannot be overtaken while its file prepares. The Android
  tests about those races keep their order of events, with the open finished first.
- iOS has no audio focus. The adapter takes the audio session on play and gives it back on pause, unload and end. Only
  the start of an interruption pauses. Losing the output in use (Android's "becoming noisy") pauses too. Playback never
  resumes by itself.
- A reload is keyed on the file's size and modification date, because iOS has no document written in place.

### App Store

These have no Android counterpart; they are what App Store Connect reads from the build.

- **Privacy manifests.** `Cassini/Resources/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the
  required-reason APIs the code and FluidAudio call: UserDefaults (CA92.1, the app's settings), disk space (E174.1,
  the checks before recording, a checkpoint and a model install; 85F4.1, "Space for about N more" on the recording
  screen), file timestamps (C617.1, sizes and dates of files in the app container) and system boot time (35F9.1,
  `ProcessInfo.systemUptime` timing the playback position saves). The Live Activity extension links CassiniNotebook
  and has its own manifest, `CassiniActivity/PrivacyInfo.xcprivacy`, with C617.1 only: its binary references no
  UserDefaults. `AppStoreManifestTests` checks both in the built app.
- **Export compliance.** `ITSAppUsesNonExemptEncryption` is false: the app uses only HTTPS through `URLSession` and
  CryptoKit hashing, so no build waits for the encryption question.
- **Memory limit.** `Cassini/Cassini.entitlements` asks for `com.apple.developer.kernel.increased-memory-limit`, which
  raises the limit on devices that allow it. Android has no equivalent.
- **App Privacy answers.** "Data Not Collected", no tracking. Model downloads send no user data.

## Android tests without an iOS port

- **`NoteViewModelTest#theExportAfterProcessDeathStillRuns`.** Android exports through a file picker, so the export
  waits for the picked target across a process death. iOS makes the file first and then offers the share sheet;
  nothing waits for a target, and a closed share sheet removes its file.

- **Room, SQLite and the sealed document:** `sqliteHasFts4WithUnicode61AndRemoveDiacritics`,
  `replacingTheCacheKeepsTheFtsDocid`, the adopt and marker cases of the queue and job tests, and `CheckpointData` and
  the word log.
- **Parakeet and streaming diarization:** `SpeechWindowsTest`, `TurnHistoryTest`, and the draft-naming cases of
  `SpeakerNamingTest`, `SpeakerStatsTest`, `ProgressTrackerTest` and `SheetBehaviourTest`.
- **Android platform:** foreground-service types, a refused service start, the ongoing-notification tests,
  `belowApi33OnlyTheMicrophoneIsAsked`, `TrashViewModelTest#backCloses`, `LicensesBackTo`, the AAC file-limit tests,
  the platform Opus encoder half of `PortableDocumentTest`, and `RedirectPolicyTest` (see
  [Speaker analysis](#speaker-analysis)).
- **Races that cannot happen** with a synchronous `AVAudioPlayer` open are kept in their event order, with the open
  finished first. Purge races that need two threads are ported as the interleavings at the first step.
- **Restoration after process death** is covered by unit tests of the restore rules (`SavedNoteOverlay`,
  `NoteOverlay`, `SavedLibraryDialog`), not by a UI test. XCUITest's `terminate()` after sending the app to the
  background discards the scene's saved state.
