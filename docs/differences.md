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

- **Engine.** Both apps run Parakeet Ultra INT8 over 28 s windows. iOS's `ParakeetTranscriber` (CassiniInference)
  is Android's `IncrementalRecognizer`: the file read as 16 kHz mono floats through `AVAudioConverter` (channels
  averaged), `IncrementalTranscript` windows, each window decoded by `ParakeetDecode` (Android's
  `Parakeet.transcribeWithDecoder`) with `DecodePolicy.wholeSpans` and SPEECH cutting when Silero VAD is installed,
  QUIET otherwise. The native recognizer and detector are CassiniSherpa's `ParakeetDecoder` and `SileroDetector` over
  sherpa-onnx's C API, behind the `SpeechDecoding`/`SpeechDetecting` ports, so the transcriber and the job are tested
  on the host with fakes. Decodes run on one dedicated thread at `.userInitiated` (`InferenceThread`); the recognizer
  is made with the first window and released when the words step ends, before the speaker step loads its models.
  Differences:
  - **Apple Speech fallback (decision D2, iOS only).** A device that cannot hold Ultra keeps Apple's `SpeechAnalyzer` /
    `SpeechTranscriber` (`AppleSpeechTranscriber`), with the speech language setting and its failure codes; so would a
    build without the native runtime, which every iOS build now links. `AppEnvironment` asks the pure
    `SpeechCapability.choose(linked:capable:)` once at launch, whether or not Ultra is installed: a job downloads it
    with consent, as on Android. The capability rule (at least 5 GiB of physical memory) is **provisional until the
    WP0 device gate**. On the Apple path the file goes to the
    analyzer one second at a time from the resume point; a "window" is one finalized result, and a final result
    without words counts as an empty finalized segment so silences still advance `doneMs`. Its block size and resume
    point live in `AppleSpeechWindows` (iOS-only `AppleSpeechWindowsTests`).
  - **Memory.** Before the model loads and before each window the transcriber checks `os_proc_available_memory()`
    against `ParakeetMemory` (1200 MiB before the load, 640 MiB before a window, from the simulator figures and
    **provisional until the device gate**) and fails with `MEMORY` instead of being ended by iOS. Android pauses with
    `MEMORY` on a Java `OutOfMemoryError`, which iOS cannot catch.
  - **Cancellation** stops before the next native call: a flag the decoder checks before each recognizer call, set by
    the task's cancellation handler (Android interrupts the thread). It ends `CANCELLED`, or paused when a pause asked
    for it. A recognizer failure is the `JobFailure` itself (`TIMINGS`, `MODEL`, `MEMORY`).
  - **Models.** The transcriber asks the installer for SPEECH when Ultra is missing (with consent) and, online, when
    only the detector is missing (`ParakeetModels.request`, Android's `installModels`). Before any native object is
    made, Ultra's revision directory must be complete, else `MODEL`.
  - **Check before the first load (D16 §4, iOS first).** Before the first load in each session every file of Ultra and
    of the detector is hashed against its pins (`ModelVerifier`) on the inference thread, stopped by the run's cancel
    flag, while the job shows the Preparing stage. A detector that fails is removed and the run cuts at quiet points;
    an Ultra that fails is removed and the run fails with `VERIFY`; the next run downloads it again through the shared
    installer, as a missing model, with consent
    (`ParakeetTranscriberTests.aModelThatFailedItsCheckIsDownloadedAgainByTheNextRun`). D16 §6's copy and
    older fallback copy is superseded by D78's live Whistle/verified-Parakeet choice. Android has no such check
    yet. A resumed run whose detector is removed between its windows cuts the rest at quiet points, as it already did
    when the detector was installed between runs, and its `x-segmentation` names quiet points for the whole
    transcript: the checkpoint does not record how its earlier windows were cut (nor does Android's).
  - **Language.** Parakeet takes none: its jobs and checkpoints carry `""`. Its words are written, and their body
    counted at every window, with `und` (see "Transcript language" below). Android counts its decoded windows with
    `""` and stamps `und` only on the finished transcript, so iOS's per-window check is 17 bytes stricter.
  - **DC-robust speech detection (D26.1, ahead of Android).** Silero has no DC handling of its own, and a microphone
    with an ADC offset changes what it finds. The detector hears the track through `SpeechInputFilter`: WebRTC APM's
    2nd-order Butterworth 100 Hz high-pass (`silero-input-hpf-butter2-100hz-v1`), with the spec's exact binary64
    coefficients, scalar Double arithmetic and the denormal guard. `ParakeetTranscriber` filters the samples once as it
    reads them (`SpeechInput`), so the filter's state runs on across the 28 s windows and their 2 s overlap is
    filtered once. A resumed run starts the filter from zero at its restored window. The spec allows that: no priming,
    and zero-state steps never made a segment. The recognizer, the word gate, the speakers' input and the recording
    stay raw. On the shared vector `dc-quiet-jfk-v1`, at iOS's 0.18 threshold, the offset makes Silero find spans the
    control does not have; the desktop's 0.5 finds none. Filtered, the vector's spans equal the control's
    (`CassiniTests/DCVectorTests`). Parakeet hears no words at that vector's level (34 LSB) even without an offset. At
    the failing microphone's own level (JFK at 1/8 over the same offset), the filtered spans and Parakeet's words equal
    those without the offset. Android has not landed D26.1 yet; its section of the spec asks for the same filter.
    The provenance's segmentation text stays Android's word for word, and changes with Android's when it lands D26.1.
    iOS has no structured field for the stage: every provenance field is one of the format's. The stage's name lives
    in `SpeechInputFilter.stage`.
- **Decode rules.** Android's pure decode rules are ported one to one into
  CassiniNotebook/Transcription with the same constants and algorithms: `SpeechWindows` (`DecodePolicy`, quiet
  pieces, split, fixed, padding, windows), `DecodeSession`, `WordGate`, `SeamMerge`, `IncrementalTranscript`,
  `SpeechFeed`, `TokenWords`, `ProcessingSpeed`, `ParakeetDecode`, and the cutting provenance strings
  (`DecodeCutting`, Android's `Parakeet.Cutting`). The differences are of naming and platform only:
  - Android's `TimedWord` (a word with its extension cap) is CassiniCore's `DecodedWord`, because the note model
    already has a `TimedWord`. `Span`, `Window` and `Chunk` are `SampleSpan`, `DecodeWindow` and `DecodeChunk`, so
    they do not clash with the standard library's `Span` or SwiftUI. Constants are lower camel case
    (`MAX_SAFE_MS` is `maxSafeMs`); `DecodeConstantsTests` pins each to Android's value.
  - Cancellation is the task's (`Task.checkCancellation()`, `CancellationError`) where Android checks the thread's
    interrupt flag and throws `CANCELLED`.
  - `SpeechFeed.scan` does not resample. iOS reads every recording at 16 kHz through `AVAudioConverter`, so a 16 kHz
    recording is its own copy and any other rate passes its 16 kHz copy (`copy16k`). Android's windowed-sinc
    `resampleTo16k` and `StreamingResampler` (`ResamplerTest`) are not ported.
  - `IncrementalTranscript(restored:)` throws `IncrementalState.Invalid` for a state no run could have saved, where
    Android's `require` throws: the state comes from a checkpoint on disk.
  - `TokenWords` throws `JobFailure.timings` (`JobFailure` is an `Error` on iOS) where Android throws `TIMINGS`.
  - `LongRunMeasurementTests#checkpointPathOfATenHourRun` measures iOS's own checkpoint path (the typed recognizer
    state and `CheckpointState.encoded()` of segments) instead of Android's three word-log variants, because iOS has
    no word log. `CASSINI_MEASURE_HOURS` shortens it.
- **Speech language.** On Apple Speech devices iOS asks for a speech language in Settings, because Apple's models are
  per language ("· Installed" marks the ones on the device). Parakeet devices have no such picker: Parakeet recognises
  any language on its own, as Android does. A language that Apple does not offer counts as nothing to download, and the
  job fails with `UNSUPPORTED_LANGUAGE` rather than waiting for a consent that cannot help. `UNSUPPORTED_LANGUAGE` and
  `RESERVATION_LIMIT` (Apple's speech assets) are failure codes that exist only on iOS. So that nobody transcribes in
  the wrong language unawares, the consent screen on those devices names the language and where it is set (D59 (2)):
  "Cassini recognises speech in Italian (Italy). To transcribe another language, change it in Settings › Speech
  language." It is not shown for Identify speakers, which recognises no speech. iOS has no first-run screen, so the
  consent screen at the first transcription is the only place it appears.
- **Sizes.** Every size on the model download screen and the On-device models rows follows the shared rule of
  `ux-draft/format-vectors.json` (`sizeRule`, v4: MB rounded half up, GB with one decimal from 1000 MB, KB below 1 MB;
  `SizeText`, tested with the vectors), so Ultra's download reads "443 MB" as D4 and D16 write it. Android still
  rounds to tens from 100 MiB (`ModelCatalog.mebibytes`: 440, 1230) and should adopt the rule. The speech part shows
  Ultra's download alone, **443 MB**, as D16's model rows do: its speech detector (458 KB) has no row of its own, is
  installed with it and counts in the free space. Android sums every model of the part
  (`part.models.sumOf { downloadBytes }`), which its rounding to tens hides (440 either way). The speakers row is the
  diarizer and CAM++, 62 + 26 MB, shown as 88 MB (iOS shows them as one row). On a Parakeet device the consent screen
  lists each missing part with its size and the body quotes their total ("Cassini needs a one-time download of about
  **531 MB**", the figure in bold and kept on one line, as Android's), and Settings shows the speech row as "INT8 · 443
  MB" (Android's copy). The free space is the whole install's `ModelPlan` figure, about 1231 MiB, shown as "1.2 GB" by
  the rule. The banners'
  "N MB" figures (download progress, DL_NO_SPACE) keep their earlier rounding.
- **Speech model size on Apple Speech devices.** iOS does not report the size of Apple's speech assets before they are
  downloaded. On a device that keeps Apple Speech, Settings shows "Managed by iOS" instead of a size, and "Not
  available" when Apple has no model for the language or the device. The model download screen lists the speech part
  without a size and its body without a total. Its free-space check and the "Needs about N free" figure use an
  estimate per part: 512 MiB for the speech model (`ModelDownloadPlan.speechInstallBytes`) and the pinned files plus
  32 MiB for the speaker models. DL_NO_SPACE quotes the plan's figure (on a Parakeet device, the speech install's
  `ModelPlan` figure). When there is no figure, its body reads "Free some space and try again." and never "0 MB".
- **Download progress.** Apple's assets report only a fraction, not bytes. `DownloadProgress`
  therefore carries per-mille counts, and the download banner has no byte counts. Apple install errors map to
  `NO_CONNECTION` (URL connectivity errors), `NOT_ENOUGH_STORAGE` (out of space) or `INSTALL`. Apple gives no
  "free about N MB" figure for its own downloads.
- **Native runtime.** Every iOS build links the same sherpa-onnx fork commit as Android, codemyriad `0c2ee3f` (D16
  §1), against the same ONNX Runtime (1.27.1), as static xcframeworks with only the C API and no TTS, from the fork's
  release `v1.13.7-cassini-mobile.1` (`Package.swift` binary targets; `scripts/build-sherpa-xcframework.sh` rebuilds
  the same bytes, and `CASSINI_SHERPA_LOCAL=1` links that local build; Android's AAR from the same release keeps its
  JNI layer). Speaker diarization is on in
  both, and both apply Android's `scripts/streaming-diarization.patch` (Sortformer's incremental mode). That patch adds
  its entry points only to JNI and Kotlin, so iOS adds a second, iOS-only patch,
  `scripts/streaming-diarization-c-api.patch`, with the same three calls in the C API
  (`SherpaOnnxOfflineSpeakerDiarizationProcessStreamingChunk`, `…SaveStreamingState` with
  `…DestroyStreamingState`, and `…RestoreStreamingState`, which rejects more than 200000 floats as the JNI does).
  Android builds arm64-v8a and x86_64; iOS builds the device (`ios-arm64`) and the Apple-silicon simulator
  (`ios-arm64-simulator`) only, so there is no x86_64 simulator slice. Android's goldens come from the x86_64 emulator; the arm64 simulator, decoding FLEURS-it short whole without
  the 500 ms tail, gives "4.892" where the golden has "4892" and otherwise matches it word for word (with the tail it
  also gives "raggiun" for "raggiunge"; the goldens decode VAD spans, which the spike does not), so iOS will keep
  goldens of its own.
- **Pinned model downloads (D4, D16, D53.1).** `CassiniEngine/Models` ports Android's
  `ModelCatalog`, `ModelPart` rules, `ModelPlan`, `RedirectPolicy`, `ArtifactFetcher`, `DistManifest`,
  `ModelInstaller`, `ModelRepository` and `ModelInstallOwner` (as `PinnedModelInstaller`) with the same dist pins
  (`parakeet-ultra-0.6b-int8`, `silero-vad`, `nemotron-3-diarization-int8`, `campplus-voxceleb-16k`, each by
  `(id, source_sha256)` with both SHA-256 values of every file), URLs, figures (440 + 62 + 26 = 528 MiB, about
  1230 MiB free: every installed file plus the largest single download, the 431 MiB encoder, because the files install
  one at a time and each `.zst` goes once its file is in place) and tests. Every model comes from `dist.gocassini.com`
  only, through its manifest; Hugging Face and GitHub are gone from the catalog and the allow-list. The app builds
  one repository and one `PinnedModelInstaller` (`PinnedModels`) and installs Ultra with its speech detector, and
  Android's speaker models (Nemotron Sortformer and CAM++), through it, so a job that joins the standalone download
  fetches each file once. The standalone speech download (Settings, the model download screen) shows Downloading,
  then Checking files; its Cancel is described under "Cancel during a job's download". On devices that keep Apple Speech
  because they cannot hold Ultra (a platform constraint), the Model download screen shows `ModelDownloadPlan`'s
  estimate for the speech part. The differences that remain:
  - **Layout without a marker.** Android keeps a `verified` marker holding the source hash in
    `models/<id>/<source_sha256>/`. iOS collects a model's files and the host's `NOTICE.txt` in
    `models/<id>/.<source_sha256>.staging/` (which keeps `.part` files and checked files across failures and app
    kills), writes it through (`F_FULLFSYNC`) and renames it into place (`RENAME_EXCL`), then writes the parent through,
    as the desktop does; the directory's name is the pin. A model is ready when its revision directory has every file
    at its pinned size and a `NOTICE.txt`. A revision that is there but incomplete, or fails its check, is retired by
    renaming it to `.remove-<UUID>` before it is deleted. The root stays `Application Support/CassiniModels` (not the
    desktop's `…/Cassini/models`): `Application Support/Cassini` holds the backed-up note folders. Directories of earlier
    development builds (`parakeet-ultra/`, `vad/`, `speaker-models/`), other revisions and retired revisions are deleted
    at launch (`ModelRepository.prune`, D51: nothing is migrated).
  - **Manifest checks.** Both apps read the live manifest before a download and take only the pinned row, checking
    every artifact entry against the pins. iOS also requires the manifest's `base_url`, each entry's URL to be
    `base_url/key`, `encoding` `zstd-seekable` and `format_version` `0.1.0`. A missing or contradicted pin is iOS's own
    failure, `DOWNLOAD_PIN_UNAVAILABLE`: the banner "Model not available" says to update Cassini and has no Retry
    (Android reports `VERIFY`, File check failed, with Download again). A manifest longer than 1 MiB, sent or
    announced, is refused the same way. The On-device models row of that part keeps Android's single failed status
    ("Download failed — tries again next time", which opens the model download): the next install, by a job or the
    row, reads the manifest again (one small request) and fetches nothing unless the host offers the pin again, so a
    pin restored on the host needs no update. An unreachable manifest is a download error (`NO_CONNECTION` or
    `INTERRUPTED`), and kept parts stay.
  - **NOTICE.txt** is downloaded from the host into each installed revision, as the desktop does, and About › Model
    notices shows it from an installed revision (the newest). Android bundles a pinned copy instead.
  - **Resume.** Both resume a part with `Range: bytes=<length>-`, restart from zero on any `200` to a resumed request,
    whatever its entity tag (the size and SHA-256 checks decide), and delete the part on a `416`, so a proxy that strips
    entity tags cannot make every retry fail the same way. iOS also sends `Accept-Encoding: identity` and
    `If-Range: "<compressed sha256>"` (Android sends only `Range`), and adds two checks: a `206` must carry that tag,
    else it fails as a download error and deletes the part (Android takes any `206` whose `Content-Range` fits); an
    answer with a `Content-Encoding` fails as a download error and keeps the part. Parts are named after the compressed
    SHA-256 (`<sha256>.part`), so a part only ever resumes the file it is a prefix of. A cancel while a checked `.zst`
    is decompressed keeps the `.zst`; it is deleted only once its file is in place, a retry neither downloads it again
    nor counts it in the free-space check, and a retry that finds the file in place deletes a `.zst` an app kill left
    beside it. A full disk while decompressing fails with `NOT_ENOUGH_STORAGE` and another local write failure with
    `INSTALL`, not File check failed (`VERIFY` is kept for a stream the decoder refuses). Each decompressed file is
    written through before its rename. Files already checked in the staging directory are hashed again on a retry rather
    than downloaded.
  - **Progress.** Within a model only the last file's check reports as Checking files; the checks of the files before
    it keep the progress at their end as downloading, so the status does not alternate for each file.
  - **Provenance** names Ultra `parakeet-ultra-0.6b-int8@<source_sha256>` (D16 §5); Android still writes
    `moondream/parakeet-ultra INT8`. The revision and the checkpoint model are the source SHA-256 on both.
  - **Transport.** `ArtifactFetcher` talks to an `HTTPTransport` port. The app's adapter, `URLSessionTransport`, is
    a data-task `URLSession` whose delegate refuses every redirect, so `RedirectPolicy` decides each hop as
    `HttpURLConnection` with `instanceFollowRedirects = false` does on Android. It asks for `Accept-Encoding:
    identity`, so the byte counts are the file's. A background `URLSession` is not used: it follows redirects itself
    and hides the Range answers.
  - **Cancellation** is Swift task cancellation, checked between blocks where Android checks the thread's interrupt.
  - **Network check.** iOS has no `NET_CAPABILITY_VALIDATED`; `NetworkPath` reads `NWPathMonitor` (satisfied, and
    whether the path is expensive or constrained). Like Android, the consent screen has no mobile-data note.
  - **A full disk** during a download is `NOT_ENOUGH_STORAGE`, as iOS reports it as its own error. Android reads it
    as an I/O error (`INTERRUPTED`). Both check the free space before the first byte.
  - **Stopped by the system.** The installer has no `startDownload`/`stopDownloads()`: the standalone download is
    `ModelInstalls`, one more caller of the installer, and the end of its `BGContinuedProcessingTask` (Android's
    foreground-service time-out) stops its own wait and shows "Download stopped" there. The ported
    `ModelInstallOwnerTest` cases start that caller with `install`.
  - **Compressed downloads.** Every model file is seekable Zstandard, which Apple's Compression framework does not read.
    `ArtifactFetcher.fetchCompressed` takes a `Decompressing` port, which the app fills with `ZstdDecompressor`
    (CassiniInference, `ZstdModelTest` ported as `ZstdDecompressorTests`).
    `aCompressedDownloadChecksOnceFromZeroToItsSize` runs with a stand-in format.
  - **Consent** follows Android (`models.consentAt`, or Parakeet installed). Only on devices that keep Apple Speech
    does the Apple rule add to it (assets installed, or not offered for the language); on a Parakeet device assets
    iOS installed for dictation are no consent to the Ultra download
    (`ModelConsentTests.appleAssetsAreNoConsentOnAParakeetDevice`).
  - `ModelInstallOwnerTest` is ported as `PinnedModelInstallerTests`.

### Speaker analysis

- **Pipeline.** Both apps use streaming Sortformer (NVIDIA Nemotron-3-Diarization INT8) and CAM++ on sherpa-onnx. A
  Parakeet run tells each 28 s window's speakers apart as it decodes (`WindowSpeakers`, Android's
  `TranscriptionJob.onWindow`): `Diarization.assign` gives each word its slot's id, and the voice-clip cache keeps up
  to 45 s of each speaker in `work/clips.pcm`. After the words, a CAM++ print is made for each speaker from its
  clips, with the draft's merges applied, and the prints are matched with the saved voices. When the diarizer fails,
  the later windows get one voice, as on Android. `NativeBudget` (Android's) lets one job's native models load at a
  time, so a job whose predecessor still holds them shows "Finishing the previous note…". The differences:
  - **After the words.** An Apple Speech transcription (on the fallback devices) and a speakers-only job stream the
    whole file through the same `WindowSpeakers` after the words (`SpeakerAnalyzer.analyze`). That draft has one
    voice, so it has no draft naming.
  - **Memory.** Before the diarizer loads, `os_proc_available_memory()` must leave 400 MiB, and 200 MiB before the
    prints (`SpeakerMemory`, provisional until the device gate). Below that the speakers fail (one voice) rather than
    the job. Android catches an `OutOfMemoryError` instead.
- **Draft naming** follows Android's `names.json`. The format and the reducers are Android's `CheckpointNames`
  (`DraftNames`), and one owner per note serves both the job and the Note screen (`DraftNamesStore`, Android's
  `NamesStore` and `NamingGate`). After each window, a speaker with at least 4 s of clips, and 10 s more than at its
  last try, is matched live with the saved voices (`LiveMatching`). The job closes naming once the words are done, and
  then puts the merges, the labels, the "Not X" answers and the Remember choices into the note with the speakers. The
  differences:
  - **Automatic naming.** While "Name strong matches automatically" is off (see below), a strong live match is offered
    as "Is this Luca?" and does not name the speaker.
  - **Saved voices only.** Live matching compares against the saved voices. Android also lets the note's own voices
    of an earlier run compete, then drops their matches from the live state (`noteLocalVoicesAreNoLiveMatch`). On iOS
    those voices take part only in the matching after the words.
  - **A failed write.** When `names.json` cannot be written, iOS keeps the names in memory and writes them again at
    the next change. Android fails the job with `SAVE` if the names cannot be written when it starts.
  - **No coordinator in between.** The Note screen changes the draft's names through the store (`mutateIfOpen`),
    which applies a change and writes the file under one lock.
- **Words in a gap** between turns go to the nearest turn, as on Android. A speaker's overlapping turns count once.
  Without a valid turn the transcript stays as it is, and the note records `speakerAnalysisFailure = .empty`.
- **Voiceprints** are Android's: CAM++ prints of 512 values, tagged with the model's SHA-256, matched with Android's
  thresholds (0.72 automatic, 0.50 suggest, 0.08 margin) and its 4 s minimum, which Remember needs too. Voices saved
  by iOS builds before this one hold WeSpeaker embeddings from FluidAudio. They are stale, and the person is named
  again in a note, as Android does for prints of another model.
- **Automatic naming is opt-in.** Settings has "Name strong matches automatically", off by default. While it is off, a
  suggestion reads "Is this Luca?", and the Remember subtitle says "Future notes will suggest Luca" instead of Android's
  "will name Luca automatically".
- **Speaker model install.** The speaker models come from the pinned catalog through the shared
  `PinnedModelInstaller`, as on Android: the diarizer and CAM++ as seekable Zstandard from `dist.gocassini.com`,
  unpacked by `ZstdDecompressor` (facebook/zstd 1.5.7, the release that zstd-jni bundles). Each file is checked
  against both of its pinned SHA-256 values, every redirect follows `RedirectPolicy`, and a request made during an
  install joins it. Before their first use in each session both are hashed again on the inference thread (iOS only,
  D16 §4): a diarizer that fails is removed, so a streaming run shows every word as one voice and the next run
  downloads it again, and a whole-file analysis fails with File check failed (Download again installs it); a CAM++ that
  fails is removed and nobody is named. A file that cannot be read (an I/O or permission error) is not proof of damage:
  it retires nothing and is never loaded unchecked. A diarizer that cannot be read gives the streaming run no engines
  and fails a whole-file analysis with `MODEL` (Download again could not help); a CAM++ that cannot be read is left out
  until a later check reads it. A build without the native runtime reports the speaker models as unsupported
  and has no speaker step.
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
- **One voice (D59, amended after Android R9).** As on Android, the words of a run that no speaker step told apart
  (the setting is off, the speaker models were declined or failed, or the step failed) are one speaker whose id is new
  to the run, labelled "Speaker 1" in the app's language when the words are saved (`NoteSpeaker.oneVoice`), so the
  screen, the Speakers list and every export show and write "Speaker 1". The id is the run's speaker prefix and `1`,
  the id its diarizer would give its first speaker: Android writes `diar_<run uuid>_1`, iOS `<UUID>_1`
  (`WindowSpeakers.freshPrefix()`, the same form as its diarized ids). A streaming run uses its own prefix, restored
  from the checkpoint on a resume; any other run takes a fresh one when it saves the words. So Transcribe again never
  reuses an earlier run's speaker, nor the name or saved voice the user gave it (D56), in the note or in an exported
  document. The job writes it when it saves the words (`TranscriptionJob.saveTranscript`); a run resumed for its
  speaker step finds those words saved and keeps them. The Apple Speech recognizer and checkpoints without streamed
  speakers keep words without a speaker until the job saves them. The draft shows those as Speaker 1 too, but its
  header there is only a label (`NoteTurn.nameableSpeakerID`): that speaker has no id until the words are saved,
  so it is named in the note once they are. Android's draft words already carry `diar_<run>_1`, so its one voice
  can be named in the draft. The speaker step that follows, or Identify speakers later, replaces the one voice in
  the transcription's own version, as long as it is still a single unnamed speaker linked to no saved voice (a
  speaker step that found one unnamed voice counts the same); a named one is kept as a version. Notes saved before
  keep their passages as stored (D51).
- **Speaker ids per run (D56).** Every speaker step writes ids of its own: the streaming diarizer of a Parakeet run
  and the whole-file analysis (an Apple Speech transcription, Identify speakers) each take a fresh
  `WindowSpeakers.freshPrefix()`, so their speakers are `<UUID>_1`, `<UUID>_2`, …, as Android's are
  `diar_<run uuid>_n`. A new analysis never gives its speakers an earlier run's ids, so no name, saved voice or
  `voiceSource` of the earlier run lands on them by id. Names and exclusions reach the new speakers only through a
  voice match and the time overlap with the transcript shown, as before. Labels stay "Speaker N" by order of first
  appearance (D47).
- **Passages without a speaker** are only those the user set to no speaker (Edit passage, "Unassigned"). They show as
  "Unknown speaker" in amber, and their header is not a button. In exports they get the id `unassigned`, the id the
  sealed document uses. Android's words always have a speaker. The TXT, SRT and WebVTT exports label them "Unknown
  speaker" in the app's language, and the Cassini document writes the same label into its `speakers[]` entry for
  `unassigned` (D47, parity report risk 4), so every reader shows what the app showed rather than the raw id, which
  Android and this app read as an unlabelled "Speaker N". The entry is added only when a word uses it. A verified source
  that already has an `unassigned` entry keeps it verbatim, label included: it was written when its words were produced,
  and an export in another language must not rewrite it. Only renaming that speaker in the note changes its label, as
  for any speaker.
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
- **Speaker placeholders (D47).** A placeholder is written in the app's language when the speakers are told apart:
  "Speaker N", "Voce N", "Intervenant N", "Hablante N", "Locutor N" or "Orador N" (`DefaultLabels.words`, the
  glossary's "Speaker {n}"). Every screen shows it as stored, in whichever language wrote it. A speaker with no label
  reads "Speaker N" in the app's language. Every language's word counts as a placeholder, not a name. Android still
  shows its placeholders in the reader's language.
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

- `work/checkpoint.json` uses iOS's own format (`CheckpointState`, version 2). It holds the source file name, a
  `length:mtime` signature, `model` (Android's member: Parakeet's revision, or `apple-speechtranscriber <language>` on
  the Apple fallback), the words as segments, `doneMs`, `totalMs`, `elapsedMs`, `inferenceMs`, `resumedFromMs`,
  `wordsComplete` and, for Parakeet, `recognition` (`start`, `end` and `position` of `IncrementalTranscript`'s window
  in 16 kHz samples). Android's encoder, diarizer, voice-clip and word-log members do not exist on iOS, and Android's
  `recognition.chunks.window` samples are not stored: a resumed iOS run reads the file again from its start and keeps
  the window's samples as it passes them, which the signature says are the same, so it decodes exactly what an
  uninterrupted run would and the file stays small. A checkpoint that cannot be read, of another version (version 1 is
  the Apple Speech build before Ultra, as Android does not resume a Parakeet v3 checkpoint with Ultra), or that does
  not match the audio, its signature or the model, fails with `CHECKPOINT_MISMATCH`, and its `work/` is kept until
  Start over, as on Android.
- Each write keeps the previous checkpoint as `checkpoint.json.bak`, and a load falls back to it. A failed write is
  `SPACE` when the volume is full or has under 64 MB free, else `SAVE`.
- **When.** Parakeet writes one after each 28 s window, as Android does, but at most every 10 s of running time
  (`SpeechWindows.windowCheckpointDue`), because iOS's checkpoint carries every word so far. Apple Speech writes one
  once 30 s more audio is final than the last one covered, at most every 10 s. Both write at a stop and when the words
  are complete. A process death loses at most one interval.
- **Times.** `elapsedMs` counts from the recognizer's first report, so a model download is left out. For Parakeet
  `inferenceMs` is each window's decode once the model is loaded (speech detector, decoder calls and word gate), split
  from the elapsed time as Android's `IncrementalRecognizer` does; for Apple Speech the two are
  the same number, because the analyzer gives no finer split.
- **Resume.** Parakeet goes on from the checkpoint's window (Android's rule). Apple Speech starts the analyzer 1 s
  before `doneMs` and drops the words that end at or before it. A stop during the speaker step keeps the complete
  checkpoint, and the resumed run goes straight to the speakers.
- **Word body limit.** Parakeet checks the limit at every window, as Android does; Apple Speech at each checkpoint.
  Both count a 40-character speaker id per word, fail with `LONG` and keep the checkpoint before.

### Transcript language (D53 item 3, D53.2 Q2)

- A variant's language is the language of the recognizer run that made its words, written the same in the word body,
  the transcript descriptor and the processing step. It never comes from the speech language in Settings, which only
  picks the locale Apple Speech is asked for. The shared cases are coordination
  `ux-draft/library-vectors/language-tag`, copied into `CassiniEngineTests/Resources/language-tag` with its SHA-256
  pinned (`LanguageTagVectorTests`); the rule is `TranscriptLanguage`.
- **Parakeet** reports no language, so its words are `und` in all three places, as Android writes since b61ef49
  (`TranscriptionJobTest#theRecognizersLanguageIsWrittenAlikeInBodyDescriptorAndProvenance`, ported).
- **Apple Speech** (iOS only) writes the BCP-47 tag of the locale that actually ran, the one
  `supportedLocale(equivalentTo:)` picks for the request (`Transcribing.runLanguage`): a request for `it` writes
  `it-IT`, never the requested tag.
- **Versions.** `note.language` is the language of the words shown. Each kept version stores its own, a passage edit,
  merge or re-attribution keeps the language of the words it came from, and selecting a version brings its language
  back; the export seals each version in its own, and the JSON export of a version names that version's language.
  Each run's provenance record is kept (see "Provenance"), so a variant from an earlier run keeps its run's language in
  its step after a later run. Queueing a job, starting a recording and importing plain audio no
  longer set it, and the queue no longer reads it: saved progress resumes in the language its job, else its
  checkpoint (`CheckpointState.appleLanguage`), began in, so a rebuilt queue and a Restore from Recently Deleted keep
  it.
- **Imported variants** keep their stored value verbatim, with no `Locale` rewriting: `""`, `und`, `auto` and a
  non-BCP-47 `en_US` stay as stored, in the note and in an export. A note no longer rewrites its stored language when
  it loads (D51: no migration of schema 1's `en_US`). An export seals imported words as a new variant whose step is
  `user-edited`, with no `language`; Android copies the source's step. Neither app writes a language into a step of a
  run it did not make, which the shared cases pin (`provenance: null`).
- **Reading.** Absent, `""`, `und` and an earlier Mac build's `auto` all mean unknown; `und` and `auto` match in any
  case, as Android's `Transcript.knownLanguage` matches `und`. Android does not know `auto`. Document info shows a
  language only when it is known, as Android does. iOS leaves an unknown language out of the body and the descriptor; Android
  writes `""` in the descriptor. The format reads both the same.

### Provenance

- Android writes the run record into the sealed document at the end of a job. iOS has no sealed document. It keeps
  each on-device run's record beside the note, in `<note>/provenance.json` (oldest first), together with a SHA-256 of
  the words it describes. A run that makes exactly the words of an earlier one replaces that run's record. The words' members are recorded when the words are saved, the speaker members when the speaker step has
  put its speakers into the note.
- An export writes into each variant the record of the newest run that made its words (`ExportProvenance`). Otherwise the
  variant gets `{engine: cassini-ios, kind: user-edited}`. A version made by a merge also gets `x-speakerMerges`,
  `x-speakerAssignmentEditedBy` and `x-derivedFromTranscript`, as Android's merged variant does.
- **Parakeet runs** write Android's processing step (`TranscriptProvenance.parakeetRun`): `backend` "sherpa-onnx",
  `engine` "Parakeet TDT", `model` `parakeet-ultra-0.6b-int8@<source_sha256>` (D16 §5; Android writes
  "moondream/parakeet-ultra INT8"), `version` "sherpa-onnx 1.13.7; model revision <revision>", `source` "recording",
  `language` "und" (D53.2), Android's `x-segmentation` string, `x-inferenceMs` (decode time) and `x-resumedFromMs`.
  Only `model` and `device` (iOS's hardware model and OS) differ. The goldens against Android's 0.1.0
  record and the model names shown in the app follow in WP5; the Apple fallback writes the record below.
- **Keys.** The record has Android's keys (`JobProvenance`, `SpeakerAttribution.record`) with iOS's values;
  `ProvenanceGoldenTests` pins the key sets and JSON types against Android's:
  - The processing step: `backend` "Apple Speech framework (SpeechAnalyzer, on-device)", `engine`
    `apple-speechtranscriber`, `model` "Apple SpeechTranscriber <locale>" (the locale whose assets ran), `language`
    that locale's tag (see "Transcript language"), `device` the
    hardware model and OS ("iPhone17,1, iOS 26.0.1 (23A355)"; Android writes "Android CPU"), `source` "recording" as on
    Android, and `version` "Speech framework of <OS and build>". Apple names no speech model version or revision, so
    the OS build stands in for it; there is no `model revision` as in Android's `version`.
  - `x-inferenceMs`, `x-resumedFromMs`, and `x-segmentation`, which describes what iOS runs: the whole file streamed
    to the analyzer in 1 s blocks, the analyzer finding its own segments, and a resume 1 s before the checkpoint.
  - `x-speakerDiarization` is Android's Sortformer record: `backend` "sherpa-onnx 1.13.7 with Sortformer
    diarization, CPU, 2 threads", `model` "nvidia/Nemotron-3-Diarization INT8", `modelRevision`, `modelSha256` (the
    model file's), Sortformer's `threshold`, `minDurationOn` and `minDurationOff`, `elapsedMs` (the analysis without
    the model install), `turnCount`, `speakerCount`, `assignment` (Android's string) and `sourceSeparation: false`,
    with Android's `x-incrementalDiarization` beside it when the speakers were streamed. A record written by a build
    that used FluidAudio keeps its words' members, but its speaker record no longer reads, so an export of that note
    leaves `x-speakerDiarization` and `x-speakerIdentification` out.
  - `x-speakerIdentification`, counts only, as Android's `JobProvenance.identification`: `model`, `sha256` and `dim`
    of CAM++, `metric: cosine`, Android's thresholds as `autoThreshold`, `suggestThreshold` and `margin`,
    `speakersWithPrints`, `autoApplied` (speakers the analysis named from a saved voice) and `suggested` (speakers
    only offered one). With automatic naming off, a strong match is offered, so it counts as suggested. Document
    info's "N names from saved voices" reads `autoApplied`, as on Android.
  - A re-attribution (Identify speakers again over a version that already had speakers) also writes
    `x-derivedFromTranscript`, the variant it started from, and, when that variant is one of a verified imported
    document's, that document's `provenance.attribution` as `x-sourceAttribution`, as Android's
    `SpeakerAttribution.record` does. A first analysis is sealed into its transcription, so it has neither.
- **Older records.** `provenance.json` holds a list of run records since D53.2. The single record an earlier build
  wrote is not read (D51: no migration), so such a note's variants are sealed `user-edited` until it is transcribed
  again. A record without the later members still reads and exports; the export leaves out what was not recorded (the
  processing step, `x-segmentation`, `elapsedMs`, `modelRevision`, `assignment`, `sourceSeparation` and
  `x-speakerIdentification`) rather than guessing it, so Document info shows no names from saved voices for it.
- **One speaker record per run.** Each run's record keeps only its latest speaker analysis. A version of an earlier
  analysis of the same words keeps the words' members and loses `x-speakerDiarization` and `x-speakerIdentification`
  once a later analysis replaces them.

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
  that would not fit the 16 MiB word body or the 8 MiB OpusTags packet is refused before it is written. Data carried
  from the source counts toward that limit, and toward the 16 MiB manifest limit too, so private data that gzip shrinks
  well is refused as too long rather than failing in the codec. The imported file itself is never changed. What the
  export keeps of an imported document depends on how that document reads at export time, not on the state stored at
  import:
  - **Verified:** every variant stays, and the note's versions are added beside them, with the note's title and
    speaker names.
  - **Stale or unverified, nothing new on the device:** the export is the document itself, byte for byte, like
    Android's Save a copy. Its variants, provenance, `x` data and honest state all survive. Renamed speakers and a
    renamed title are not written, as on Android, whose relabel and retitle need a verified document. The note screen
    keeps such a note read-only anyway, so only the title can change.
  - **Stale or unverified, with versions made on the device (Transcribe again on a stale document):** a fresh seal
    over the same audio that holds only those versions. The note is read-only otherwise, so no edit, merge or rename
    gets here, and an unverified document cannot take a new version at all. The newest version is the default, even
    when the note shows an imported version. The imported variants are not sealed again, because the audio does not
    vouch for them; the note still shows them, and no provenance record names them. What the source manifest holds
    apart from its transcripts and audio is carried verbatim (D53.2 Q3, SPEC "Extensibility"): `x` (desktop notes
    under `x["gocassini.com"]`), any top-level member the schema does not define, the `meeting` with its id,
    `recordedAtLocal` and unknown members (only the title, `createdAtUtc` and `durationMs` are written afresh), and
    the `provenance` members other than `speechToText`, `displayTranscript`, `meetingSummary`, `attribution` and
    `wordTimings`. Its integrity, audio, speakers, transcripts, readable transcripts, summary, attachments and
    `CASSINI_*` tags are not carried; foreign and `X_*` tags are. The speakers are rebuilt from the new words, so
    unknown members of the source's speaker entries are lost. `CassiniDocument.create(…, carrying:)` does the
    carrying, and Android's has no such parameter yet.
  - **Broken, newer-format or plain audio:** a fresh seal with only the foreign tags, since there is no manifest to
    keep.
- **Cross-app vectors** (parity report risk 6). The files of coordination `ux-draft/cross-app-vectors`, which every
  Cassini app must open the same way, are copied byte for byte into `CassiniEngineTests/Resources/cross-app-vectors`
  with `expected.json`, each pinned by its SHA-256 (a file's pin is `SHA256.json`'s). `CrossAppVectorTests` checks
  every expectation through the reader (`CassiniDocument.read`, audio verified) and through the import, down to the
  words the Note screen opens on. `two-versions-default-switched.opus` (D53.3, the shape Android writes when you choose
  a version) opens on `second-pass`, "ONE TWO. THREE.", with no change to the reader. `android-written-v1.opus`, a note
  written by cassini-android's own writers, opens on its speaker merge `words-78fd7ee6` with all five words by "Anna".
  Its first version shows "Anna" and "Voce 2", the Italian placeholder as stored, under any UI language (D47). Its
  `diar_<run>_n` ids, languages (`und`), title, tags (no DATE), indented bodies and provenance (`x-speakerMerges`, the
  float-widened diarization numbers) read as the vector says, with no change to the reader. A key in `expected.json`
  that no check reads fails the suite.

## Recording

- **Format.** iOS captures 48 kHz 16-bit mono linear PCM into `capture.caf` (96,000 B/s) and compresses it to
  `audio.m4a` at Finish. Android captures Opus or AAC. The format chip reads "PCM 48 kHz". If compression fails, the
  CAF stays the recording, the notice REC_COMPRESSION_FAILED ("Saved in its original quality") shows, and the CAF is
  transcribed.
- **Levels (D26.1).** The note's stored waveform measures AC level (`AudioInspection.acLevel`, the mean taken off each
  sampled window), so a microphone's DC offset draws silence as silence. **The live meter does not yet:** it is
  `AVAudioRecorder`'s `averagePower`, which measures the raw level and does not expose the samples, so an offset raises
  it. The spec asks the same of Android, whose meter (`OpusCapture`) is to take each frame's mean off once it lands
  D26.1. Measuring AC live needs the capture moved to an `AVAudioEngine` tap; that is left for later. iOS has no
  silent-microphone check for it to affect.
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
  `BGContinuedProcessingTask` for the whole drain (`io.codemyriad.cassini.transcription.queue`). It is asked for at
  the drain's first claim, from the screen. The system shows "Transcribing “title”" with the job's progress and a Stop
  button, and each next job only changes the title. iOS grants this request only while Cassini is on the screen. A
  drain that starts in the background, or a refused request, falls back to the finite time of
  `beginBackgroundTask`. The standalone model download (Settings, the model download screen; Android runs it in the
  same foreground service) holds its own continued task under a second identifier
  (`io.codemyriad.cassini.transcription.work`), titled "Downloading models" with the subtitle "They run on this
  device" (the queue's says "Your audio stays on this device"; it names no source, as Apple's speech assets come from
  Apple and the rest from the model host), from its start to its end (`ModelInstalls`), so a 443 MB Ultra download
  goes on after Cassini leaves the screen. Its progress weighs each part by its download, so it never goes back when
  the next part starts. When iOS takes that time back, or the person presses Stop, the standalone download stops as
  its Cancel does and the part shows "Download stopped" (STOPPED_BY_SYSTEM), as Android's `stopDownloads()` shows it,
  until its next install.
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
  `cancelDownload()` with `Cancel.RESTORE` does. The Cancel of a standalone Parakeet or speaker models download (the
  Settings banner, iOS's own: Android has one banner for both) ends only the standalone's wait; the shared installer
  stops the install when nobody else waits on it, as Android's `ModelInstallOwner` does for a caller that leaves. A job
  that waits on the same install, or on one that the standalone request waited to end, goes on, and its card's Cancel
  stops it as above; so the job is never paused as interrupted by a Cancel it did not get
  (`PinnedModelInstallerTests.theStandaloneCancelLeavesAJobsInstallRunning`). A job that is waiting on Apple's speech
  assets is not ended by it either: AssetInventory shares the download itself.
- **The stepper** reads Reading, Preparing, Words, Speakers & matching, Saving (Android: Words & voices, then
  Matching). When the speaker step will run, the words fill the bar to 85 % and the speakers fill it from 85 % to 99 %.
  The headlines are Android's, plus "Finding speakers". During the words, the time left counts the words plus the
  measured finalization. The speaker step extrapolates from its own progress.
- **Read-only gate.** Any job row, except one waiting for consent, makes the transcript read-only, as on Android. The
  draft of a Parakeet run has its own gate, as on Android: its speaker headers open Name a speaker and its "Is this
  Luca?" cards answer while the job lets the draft be named, and once the job closes naming a tap says "Saving — you
  can rename when it's done" (Android's SAVING). While the transcript's gate is closed, its suggestion cards are hidden, and every sheet of the Note screen follows it through `NoteScreenModel`: the
  Speakers list's speakers and Add a speaker are disabled, Identify speakers waits, Edit passage is locked, and an open
  Name a speaker sheet saves nothing.
- **The progress card's footnote** reads "Transcription runs on this device. If iOS stops it in the background, your
  progress is kept." in place of Android's "Keeps going if you leave the app…" and its "Notifications are off, so
  progress shows only here." variant. iOS shows a running drain's progress in its own continued-processing UI whatever
  the notification permission is, and may end that time (see "When iOS takes the time back" above), so neither of
  Android's lines holds.
- **The draft** shows Apple's volatile results (on the fallback devices) as words that may still change. It follows its end as on Android: the
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
- **"Recently Deleted"** instead of "Trash", as in Photos and Notes. The rest of the copy is Android's.
  - Each language names the place the way Apple does: "Eliminati di recente", "Suppressions récentes" and "Eliminado
    recientemente".
  - Both Portugueses use the short "Apagados". "Apagados recentemente" did not fit beside the screen's Empty button at
    larger text sizes (`testNoTextIsClippedInBrazilianPortuguese`).
- **Forget all voice data** in Saved voices. It is offered when nobody is saved but notes still hold voiceprints, and
  also for a damaged list, so there is always a way back.
- **Settings sections** for Transcription (the speech language on Apple Speech devices, and "Transcribe after
  recording or import", on by default), Speakers (identify speakers, name strong matches automatically) and Your
  library (counts and duration). Turning automatic transcription off makes every finish and import audio only.
- **Notices that exist only on iOS:** REC_INPUT_LOST, REC_COMPRESSION_FAILED, NOTES_UNREADABLE ("2 notes can't be
  read"), DL_PIN_UNAVAILABLE ("Model not available": the model host no longer offers the pinned model; update Cassini;
  no Retry, closable), "No speakers were detected" and "This audio can't be played" (a playback error at run time).
- **Document info** adds "Made by" (an imported document's vendor). Its model row names Parakeet Ultra ("Parakeet
  Ultra, INT8") by the provenance model string, iOS's pin or Android's `<id> <precision>`
  (`ModelCatalog.speechModelNames`, as Android's `NoteMapping.modelName`), and Apple's speech model by its engine;
  any other model string shows its engine.

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
  and its word count. Each iOS version records its language (D53.2), but the row does not show it yet; Android adds
  " · Italian" when it is known.
- **The Undo snackbar** stays 10 s, and 30 s while VoiceOver runs. iOS has no recommended-timeout setting. The message
  is also announced, and Undo is both a button and an action of the message.
- **Header.** The iOS wordmark and the serif headline stay. The headline reads "Notes" at accessibility text sizes.

### Language and copy

- **App language.** iOS sets an app's language in the Settings app, so the row shows the current language in its own
  words ("Português (Brasil)") and opens Cassini's page there. Android has a Phone / English / Italiano control.
  Without a choice there, Cassini follows the system's language (D50.1), using Foundation's matching:
  `LocalizationTests` checks that `pt` reads as pt-BR, pt-AO as pt-PT, es-MX as es and de as English.
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
  `scripts/test.sh fast`. It fails on a value in any of the five translations that is missing, new, `needs_review` or
  empty, on a plural without its language's CLDR categories, on arguments that differ from the English, on a dropped
  "Cassini", on stale or missing keys, and on literals outside any table.

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
  required-reason APIs the code calls: UserDefaults (CA92.1, the app's settings), disk space (E174.1,
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

## Test map: decode rules

Each Android test below has an iOS test of the same name in `Packages/CassiniNotebook/Tests/CassiniNotebookTests`,
marked `// ports: <AndroidTest>#<name>`. Android's tests run at 16 and 48 kHz where they do; so do the ports.

| Android (core/src/test/.../asr, .../checkpoint) | iOS suite | Tests |
|---|---|---|
| `SpeechWindowsTest` | `SpeechWindowsTests` | 17 |
| `DecodeSessionTest` | `DecodeSessionTests` | 7 |
| `WordGateTest` (including the three `TokenWords` cases) | `WordGateTests` | 20, and 4 iOS-only |
| `SeamMergeTest` | `SeamMergeTests` | 26 |
| `IncrementalTranscriptTest` | `IncrementalTranscriptTests` | 5 |
| `SpeechFeedTest` | `SpeechFeedTests` | 8 |
| `ProcessingSpeedTest` | `ProcessingSpeedTests` | 1 |
| `LongRunMeasurementTest` (gated by `CASSINI_MEASURE`) | `LongRunMeasurementTests` | 2 |

The word gate measures AC level (D26.1): it takes off the DC, the mean of at least 1 s around the word
(`WordGate.dcContextMs`), so an offset is not sound while a click of a few samples cannot move it. A DC under
half of `minActive` (`minDC`, 8 LSB) is left on: alone it cannot make a silent sample active, and speech's own mean
over a second stays under it, so a recording without an offset is gated exactly as Android gates it
(`aDCOffsetIsSilence`, `speechOverADCOffsetIsGatedAsWithoutIt`, `aClickAfterAWordDoesNotExtendIt`,
`aFewClickSamplesAreNotAWord`). Android's fixtures are kept, except the two that make the whole recording one steady
level (0.01 and 0.1), which is all DC: there the level alternates in sign, with the same magnitude.

iOS-only: `SpeechInputFilterTests` (D26.1's high-pass bit for bit against the spec's reference loop, its state across
calls, reset, the denormal guard and the windowed track), `DecodeConstantsTests` (every constant, the provenance strings, the restore and `TIMINGS` checks),
`AppleSpeechWindowsTests` (the Apple fallback's block reading and the checkpoint cadence) and `ParakeetDecodeTests`
(`Parakeet.transcribeWithDecoder`, which Android tests only through its job).

## Test map: Parakeet adapter and job

| Android | iOS suite | Notes |
|---|---|---|
| `ParakeetDecoderConfigTest` (2), `SileroDetectorConfigTest` (1) | `ParakeetDecoderConfigTests` (CassiniEngine) | Over the pure `ParakeetConfig`/`SileroConfig` that CassiniSherpa copies into the C structs; plus the `TIMINGS` rule, padding and cancel of `SpeechWordDecoder` |
| `CheckpointGoldenTest` | `CheckpointGoldenTests` | A version 2 golden; `aChangedLanguageNoLongerMatches` became `aChangedModelNoLongerMatches`; `anAppleEraCheckpointIsNotResumedWithUltra` adapts `aCheckpointOfParakeetV3IsNotResumedWithUltra` |
| `CheckpointStateTest` | `CheckpointStateTests` | The `recognition` member and its rules |
| `TranscriptionJobTest` (windows, fsync, stop and resume, stop before the first window, body limit, mismatch, `OutOfMemoryError`) | `TranscriptionJobParakeetTests` | Over a scripted recognizer and the real `IncrementalTranscript`; the failure mapping (`MEMORY`, `TIMINGS`, `MODEL`, `CANCELLED`) |
| `TranscriptionJobTest#aMissingSpeechDetectorIsFetchedAgainOnlyOnline` | `ParakeetTranscriberTests` (CassiniInference) | With the rest of the adapter: windows on the inference thread, consent and install, revision directory and sizes, the per-session check, memory, resume, cancel |
| — (D26.1) | `DCVectorTests` (hosted, `scripts/sherpa-bench.sh`) | The shared `dc-quiet-jfk-v1` vector and JFK at the failing microphone's level through the real Silero and Ultra, with and without the offset |
| `DeviceSmokeTest` FLEURS golden | `ParakeetJobTests` (hosted, `scripts/sherpa-bench.sh`) | A real job on the arm64 simulator against iOS's own golden (`CassiniTests/Goldens/fleurs-it-short.ios.json`), because the int8 kernels differ from the x86_64 emulator's; on 2026-10-15 its text equalled Android's golden word for word |

`Golden010`, the 0.1.0 provenance record, belongs to WP5 (provenance), with `provenanceEqualsThe010Record`. The job
tests about the sealed document have no iOS counterpart (see below); those about the voice clips and live voice
matching are in the [speakers test map](#test-map-speakers).

## Test map: speakers

Android's streaming speaker rules and draft naming, marked `// ports: <AndroidTest>#<name>`. The pure rules are in
`Packages/CassiniNotebook/Tests/CassiniNotebookTests`, the stores and the job in
`Packages/CassiniEngine/Tests/CassiniEngineTests`.

| Android | iOS suite | Tests |
|---|---|---|
| `TurnHistoryTest` | `TurnHistoryTests` | 3 |
| `SpeakerBudgetTest` (the bound of both patches: the JNI's and the iOS C API's) | `SpeakerBudgetTests` | 1 |
| `VoiceClipCacheTest#speakerSlotsKeepTheirIdsWhenTheOrderWithinAChunkChanges` (slot n is `<prefix><n + 1>`) | `SpeakerBudgetTests` | 1 |
| `SpeakerStatsTest`: `aDraftAppliesItsMergesFirst`, `withoutMergesTheDraftOverloadMatchesThePlainOne` | `SpeakerStatsTests` | 2 |
| `SpeakerNamingTest`: `aDraftMergeChangesTheDraftWithTheTargetsName`, `aDraftSaveRenamesAndRemembersANewOrBoundVoice` | `SpeakerNamingTests` | 2 |
| `CheckpointNamesTest` (all but `noteLocalVoicesAreNoLiveMatch`, see below) | `DraftNamesTests`, plus the Forget reducers | 29 |
| `ProgressTrackerTest`: `draftAppliesMergesAndLabelPrecedence`, `suggestionsOnlyForPlaceholderSpeakersWithALiveSuggestedMatch`, `noSuggestionsOnceNamingIsClosed`; `CheckpointRepositoryTest#draftTreatsAStoredPlaceholderAsNoName` | `ProgressTrackerTests` (over `DraftView`) | 4 |
| `NamesStoreTest` (eight cases), `CheckpointRepositoryTest#discardDeletesTheWorkDirectoryAndTheNamesInMemory`, `ProcessingCoordinatorTest#aDraftConfirmRacingTheJobsLiveUpdatesLosesNeither`, and the naming gate | `DraftNamesStoreTests` | 11 |
| `TranscriptionJobTest`: `aRejectedVoiceIsNeverSuggestedAgain`, `labelsFollowDraftNameThenAutoMatchThenPlaceholder`, `forgetEveryoneDuringTheRunDropsTheSavedVoices` | `TranscriptionJobLiveNamesTests` | 6 |
| `NoteViewModelTest#aDraftSpeakerIsNamedThroughTheDraftNames` | `NameSpeakerModelTests` | 1 |

How the draft's names go into the note (Android's adopt) is covered by `VoicesStoreTests`: a "Not X" is never
matched, the user's name wins over a match to someone else, a stored placeholder is no name, and a Remember choice
enrols the print, unless Forget everyone came after it.

iOS-only: `SpeakerBudgetTests` also pins Android's figures and `Diarization`'s settings, the filtering of a chunk's
segments (finite, slots 0..7, milliseconds cut toward zero and held to the chunk), and `Voiceprints.normalised`;
`CassiniSherpaTests` pins `SortformerConfig` and `VoiceprintConfig` against Android's settings. The native wrappers
run in `CassiniTests/SpeakerSmokeTests` (`scripts/speaker-smoke.sh`, env-gated, arm64 simulator): streaming
Sortformer over a 45.4 s mix of two FLEURS speakers (A, B, A) in the job's 28 s windows finds two speakers with A's
slot in both of A's spans; a diarizer restored from the state saved after the first window saves the same floats and
then returns the same turns as the original; an oversized or foreign state is refused; the whole-recording call
agrees; and CAM++ gives 512-dimension unit prints, the two speakers' cosine below Android's 0.72.

Differences in the wrappers: Android's draft `DraftName` effect carries the Remember choice as `""` (a new voice) or
a voice id; iOS uses `DraftVoice.new` or `.saved(id)`. The draft merge sheet has no version line (Android's `sealed`
is null; iOS sets `MergeUI.draft`). A draft "Not X" is `reject(…, draft: true)`, which `NamingCommit` leaves to
the draft path, as Android's `Reject.draft`. A chunk that is not 16 kHz or is longer than 28 s throws
`SherpaError.invalidAudio` where Android's `require` throws; a whole recording that is not 16 kHz also throws it,
where Android resamples (iOS's decoder already yields 16 kHz); cancellation is Swift task cancellation, checked around
each native call where Android checks the thread's interrupt.

## Android tests without an iOS port

- **`NoteViewModelTest#theExportAfterProcessDeathStillRuns`.** Android exports through a file picker, so the export
  waits for the picked target across a process death. iOS makes the file first and then offers the share sheet;
  nothing waits for a target, and a closed share sheet removes its file.

- **Room, SQLite and the sealed document:** `sqliteHasFts4WithUnicode61AndRemoveDiacritics`,
  `replacingTheCacheKeepsTheFtsDocid`, the adopt and marker cases of the queue and job tests, and `CheckpointData` and
  the word log.
- **Resampling:** `ResamplerTest`. iOS converts to 16 kHz with `AVAudioConverter` (see
  [Speech recognition](#speech-recognition)).
- **Draft naming, where iOS differs** (see [Speaker analysis](#speaker-analysis)):
  `CheckpointNamesTest#noteLocalVoicesAreNoLiveMatch` (live matching compares against the saved voices only),
  `TranscriptionJobTest#aNamesWriteFailureAtTheStartIsASaveFailureNotAnOpenOne` (a failed `names.json` write keeps the
  names in memory), and `NamesStoreTest#aChangeToAReleasedDraftIsNotWritten` and
  `aLateWriteNeverStoresAnOlderValue`: `DraftNamesStore` applies a change and writes the file under one lock, so a
  release or another write cannot come between them. `NamesStoreTest#aChangeAfterAdoptDoesNotCreateWork` is ported as
  `aChangeAfterTheJobIsDoneDoesNotCreateWork`, because iOS has no adopt step. The adopt cases
  (`TranscriptionJobTest#aCrashAfterTheMarkerLeavesAnAdoptableState`, `ReconcileOnStartTest#anAdoptedNoteForgetsItsDraftNames`
  and `theAdopterAloneForgetsTheDraftNames`) belong to the sealed document below.
- **`ProgressTrackerTest#aRestoredDiarizerKeepsMatchingPossibleAfterAnEarlierFailure`.** iOS has one Speakers &
  matching step (`speakersSkipped`) and no separate matching-skipped flag.
- **Android platform:** foreground-service types, a refused service start, the ongoing-notification tests,
  `belowApi33OnlyTheMicrophoneIsAsked`, `TrashViewModelTest#backCloses`, `LicensesBackTo`, the AAC file-limit tests,
  and the platform Opus encoder half of `PortableDocumentTest`.
- **Zstandard:** `ZstdModelTest`, which decodes the real seekable Zstandard diarizer. Its decoder comes with the speaker
  package; until then `ArtifactFetcherTest#aCompressedDownloadChecksOnceFromZeroToItsSize` runs with a stand-in format.
- **Races that cannot happen** with a synchronous `AVAudioPlayer` open are kept in their event order, with the open
  finished first. Purge races that need two threads are ported as the interleavings at the first step.
- **Restoration after process death** is covered by unit tests of the restore rules (`SavedNoteOverlay`,
  `NoteOverlay`, `SavedLibraryDialog`), not by a UI test. XCUITest's `terminate()` after sending the app to the
  background discards the scene's saved state.
## Whistle production bundle (D75.2)

iOS bundles the pinned published device/simulator arm64 Needle archives and Whistle weights in a private lazy-loaded
framework/resource set. The source archives retain minos27.0; the framework is linked for iOS 18.0 with exactly the
audited SDK26 import closure, backed by native runtime26 parity and the A12 measurement on iPadOS 26; the iOS 18
runtime evidence is pending. Whistle needs Armv8.1 atomics and Armv8.3 RCpc, so the A10 iPad (7th generation) on
iPadOS 18 gets no Whistle. Android uses its own pinned arm64 input; neither mobile
platform claims x86_64 support from an arm64 archive. See [the bundle contract](../Whistle/README.md).

The iOS C API is in-process because ordinary iOS apps cannot spawn a recognition worker. A native abort can terminate
the app. The production FIR/HPF/Silero pipeline and default-limit A12/3GB memory gate passed. D78 starts new jobs
with bundled Whistle, then verified Parakeet on eligible devices. Jobs retain their backend across consent, restore
and queue rebuild. Low live memory is checked at admission/load/window and can recover without restarting. Apple's
hardware/locale/assets probe remains separate. The physical measurement did not include downloaded speaker models.
Settings and the first Whistle result use the coordinator's dismissible Parakeet suggestion only when the device
passes capability, memory and disk checks; its size comes from the speech-only pinned download plan.
