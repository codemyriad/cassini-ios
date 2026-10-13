# Architecture

Cassini for iOS is a SwiftUI app over five Swift packages, plus a Debug-only module of fakes. The packages hold every rule that Android unit-tests, so
`swift test` covers them on the Mac. The app target only composes the packages, adapts them to the device, and
renders. [Differences from Android](differences.md) explains where the design departs from Android's and why.

## Modules

```
Cassini (app: composition, adapters, views) ───────────────┐      CassiniActivity (Live Activity widget)
  │            │              │                            │        │
  │            │              │                            │        └─ CassiniShared (activity attributes and
  │            │              │                            │           intents, compiled into both targets)
  ▼            ▼              ▼                            ▼
CassiniInference   CassiniAudio    CassiniEngineTesting (Debug only: fakes of the ports)
  │ Apple Speech,    │ CAF repair,    │
  │ FluidAudio       │ libopus        │
  ▼                  │                ▼
CassiniEngine ◀──────┼──────── stores, coordinators, screen models, ports
  │                  │
  ▼                  │
CassiniNotebook      │         model, pure rules, file formats
  │                  │
  ▼                  ▼
CassiniCore ───────────────── the portable Ogg Opus document (read, verify, seal), over CZlib
```

Every arrow points at a dependency. The app imports all five packages; `CassiniEngineTesting` is linked only in Debug,
for UI-test launches.

| Module | What it holds |
|---|---|
| `CassiniCore` (`Sources/CassiniCore`) | The cassini-format document: Ogg Opus pages, the comment packet, verification, seal, relabel and retitle, `WordBodyBudget`, `SpeakerMerges`. It is tested against the format's conformance vectors. |
| `CassiniNotebook` | The note model (`Note`, versions, speakers, bookmarks, jobs) and every pure rule: search and previews, day groups, row statuses, the Note screen's modes and state, banners (`BannerKind`) and notice facts, progress tracking, checkpoints, recording policy, speaker naming and matching, trash arithmetic, and the text, subtitle and JSON exports. It also has the file formats: `NoteRepository`, `JobRepository`, `VoiceLibrary`, `SettingsKeys` and `DurableFile`. |
| `CassiniEngine` | The stateful parts, which work through ports: `NoteStore` and `JobStore` (actors), `LibraryStore`, `VoicesStore`, `SettingsStore`, the `TranscriptionCoordinator` and the `TranscriptionJob`, `RecordingController`, `PlaybackController`, `TrashService`, `NoticeCenter`, `ModelInstalls`, `ImportService` and `ExportService`, the screen models (`LibraryScreenModel`, `RecordingScreenModel`, `SettingsModel`, `LicensesModel`), navigation (`Route`, `ScreenStack`, `DeepLinks`) and `Startup`. |
| `CassiniEngineTesting` | Fakes of every port (`FakeTranscriber`, `FakeAnalyzer`, `FakeCapture`, `FakeClock`, …). Each source is under `#if DEBUG`, so a Release build links an empty module. |
| `CassiniInference` | The adapters to the recognition engines: `AppleSpeechTranscriber` (`SpeechAnalyzer`) and `SpeakerAnalyzer` with `SpeakerModelInstaller`, `SpeakerModelManifest` and `ModelNetworkGate` (FluidAudio). |
| `CassiniAudio` | Audio work that needs AVFoundation or libopus: inspection, CAF repair and Opus encode and decode (through `COpusBridge`). |
| `Cassini` (app) | `AppEnvironment`, `AppGraph`, the `Router`, the adapters (`AVCaptureAdapter`, `AVPlaybackAdapter`, `ActivityKitAdapter`, `UNNotifier`, `UIKitBackgroundRunner`, …), the thin app stores (`ProcessingStore`, `RecordingStore`, `PlaybackStore`, `ImportStore`, `ExportStore`, `NoticesStore`), the views and the string catalogs. |

## Layering

- **Ports.** `CassiniEngine/Ports` declares everything that touches the device: `Transcribing`, `SpeakerAnalyzing`,
  `AudioCapture`, `AudioPlayback`, `AudioProcessing`, `BackgroundRunner`, `LiveActivityPort`, `Notifier`,
  `StorageProbe`, `FileImporting`, `AppClock` and `TranscriptionJobRunning`. The engine depends only on these
  protocols. `CassiniInference`, `CassiniAudio` and the app's adapters implement them for the device, and
  `CassiniEngineTesting` implements them for tests.
- **Rules before effects.** A screen's logic is a pure reducer in CassiniNotebook (`NoteScreenState`,
  `SpeakerNaming`, `LibraryMapping`, `RecordingBanner`, …). Each reducer returns effects, and an engine model or an app
  store carries them out. Views read observable state and send intents. They do not write to stores or files
  themselves.
- **Composition.** `AppEnvironment` lists everything the app is built from: the root folder, the preferences, the
  clock, the locale and every adapter. `AppEnvironment.live()` is the device. `uiTesting(arguments:)` (Debug only)
  gives a separate library, a clock fixed at Thursday 8 October 2026 09:41 UTC, en_US formatting and fakes.
  `AppGraph` builds the stores from an environment and puts them into the SwiftUI environment. The hosted tests build
  the same graph over a temporary folder (`CassiniTests/TestGraph.swift`).

## State ownership and concurrency

The app is in Swift 6 language mode with strict concurrency.

- **Notes.** `NoteStore` (an actor) is where every note write meets. Engine writers (the job, the recorder, import,
  trash) call `NoteStore.mutate`. `LibraryStore` (main actor, `@Observable`) is the screens' mirror. Its `update` and
  `commit` apply a `@Sendable` change to the mirror at once, then send it to the actor as a `NoteEdit`. If nobody saved
  the note since the edit was made, the edit's result is written as the screens show it. Otherwise the change runs
  again on the stored note, so both writes survive. Every change sets only the fields its operation owns.
- **The queue.** `JobStore` (an actor) owns `jobs.json`. `TranscriptionCoordinator` (main actor) claims and drains
  jobs one at a time, inside a serial main-actor section that stands in for Android's queue `Mutex`. The
  `TranscriptionJob` runs off the main actor. Its events reach `JobProgress`, the one owner of the running job's
  progress, through one ordered consumer. The card, the rows and the system's progress all read `JobProgress`.
- **Voices.** `VoiceStore` (an actor) owns `PrivateVoices`. `VoicesStore` (main actor) plans each naming change as
  value `SpeakerChange`s. It writes the note first and then the voices, planned again on the actor, so overlapping
  writes keep each other.
- **Recording and playback.** `RecordingController` and `PlaybackController` (main actor) own the capture and the
  player through their ports. The adapters report device events (interruptions, route changes, levels) as async
  streams.
- **Off the main actor.** Search scans, import classification, document verification, checkpoint reads and Document
  info's file reads all run off the main actor, and their results are published back.

## Startup

`Startup` runs its hooks once, in fixed slots. A failing hook is reported, and the next slot still runs. Screens and
imports wait for `startup.ready()`.

1. `load`: the UI-test seed (Debug), then rebuilding bare note directories from their audio, then reading the notes,
   the saved voices and the notice facts.
2. `recover`: repairing captures that were live when Cassini closed (`CAFRepair`), sealing them plain or unplayable.
3. `reconcile`: bringing `jobs.json` in line with the notes. A job that was running is queued again, or paused by the
   system under a stored `system` hold. Notes that claimed a job they do not have are set back.
4. `voiceLinks`: deleting the voiceprints of notes that no longer exist.
5. `purge`: deleting notes whose 30 days in Recently Deleted are over (also on each activation).
6. `sweep`: removing `tmp/Exports`, stale `*.tmp` files and empty leftovers of crashed imports.

After `start()` returns, the model status is refreshed in the background, and a notification tap that arrived during
launch is opened.

## Persistence

Everything lives under Application Support/Cassini, which has protection until the first unlock, so a recording
continues after the screen locks.

```
<root>/
  jobs.json                     the queue ({version, jobs} in seq order)
  PrivateVoices/                saved voices and each note's prints (excluded from backup)
  <note id>/
    note.json                   the note (schema 2): title, transcript passages and versions, speakers, bookmarks, ...
    capture.caf | audio.m4a     the recording (PCM while capturing, M4A after Finish)
    source.<ext>                an imported file; document.opus for an imported Cassini document
    playback.caf                the decoded copy of imported Opus
    provenance.json             the latest on-device run's record
    work/checkpoint.json(.bak)  saved progress of a stopped or interrupted transcription
```

Every metadata file is written through `DurableFile`. It writes a temporary file, flushes it with `F_FULLFSYNC`,
renames it into place and flushes the directory. A `note.json` that cannot be decoded is kept as
`note.json.corrupt-<ms>`, and its audio becomes a recovered note. A file from a newer Cassini is left alone, and that
note is counted as unreadable. A permanent delete renames the note's folder to `<id>.purging` before removing it.
Preferences are in `UserDefaults`, under Android's key names (`SettingsKeys`).

## Transcription: queue and checkpoint lifecycle

1. **Enqueue.** A Transcribe (from a screen, or the hand-off after a recording or an import) passes `EnqueueRules`
   (refusals: no note, trashed, recording, unknown format, unplayable, queue unavailable) and the consent check.
   Without consent, the model download screen opens. With consent, the job is written to `jobs.json` as `queued`, in
   `seq` order.
2. **Drain.** The coordinator claims the next queued job unless the queue is held. Before the first claim it asks for
   background time: `BGContinuedProcessingTask` when Cassini is on screen, else `beginBackgroundTask`. The job runs
   only once that time is held.
3. **Run.** `TranscriptionJob` reads any checkpoint (`NoteWorkFolders`), checks it against the audio's `length:mtime`
   signature and the language, and resumes 1 s before `doneMs`. It feeds Apple's analyzer, writes a checkpoint every
   30 s of finalized audio (at most every 10 s of running time), then saves the words to `note.json`. The speaker
   step runs after that, with FluidAudio, and the provenance record is written.
4. **Stop and keep progress, or iOS taking the time back.** The job pauses with its checkpoint saved, and the row
   becomes `paused` (`user` or `system`). A `system` pause holds the queue until the user continues. Resume claims the
   job again from its checkpoint.
5. **End.** A finished job removes its row and its `work/`. A failed job stays as `failed` with its failure code until
   it is retried or dismissed. `LONG` and Start over discard the checkpoint, and `CHECKPOINT_MISMATCH` keeps it until
   Start over.
6. **Launch.** `reconcile` treats a job left `running` as interrupted (queued again with its checkpoint), or as paused
   by the system when a `system` hold is stored. Recently Deleted notes never count as waiting. A trash that was cut
   short is finished.

## Recording lifecycle

The note is created before capture begins, as a live note pointing at `capture.caf`. The controller watches storage
(the 200 MiB floor plus the room the finish needs) and the session's interruptions and route changes. It pauses on a
call or a lost input and never resumes by itself. Finish seals the note (plain, duration, title) and opens it. The
waveform, the M4A compression and the hand-off to the queue follow. The CAF is removed only once `note.json` points at
the M4A. If compression fails, the CAF stays the recording. The Live Activity mirrors the state, and its intents
carry the note id. At launch, `recover` repairs whatever was live.

## Playback

`PlaybackController` owns one `AVAudioPlayer` (through `AVPlaybackAdapter`) for the Note screen that shows the note.
It ticks every 150 ms, saves the position every 5 s while playing, and makes a final save on pause, on leave, at the
end of the file and when the app goes to the background. `MPRemoteCommandCenter` gives the lock screen and headphone
controls. Starting a recording closes the player.

## Build

`project.yml` (XcodeGen) defines the app, the `CassiniActivity` extension, the hosted tests and the UI tests. The
packages come from the root `Package.swift`. `Package.resolved` pins FluidAudio and swift-opus. `scripts/test.sh`
builds once into `DerivedData.noindex` and runs the tiers. [Validation](validation.md) describes them.
