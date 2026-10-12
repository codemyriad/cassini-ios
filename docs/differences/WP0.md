# WP0 — architecture foundation: notes for the README and later work packages

## Differences from Android

- **Navigation.** Settings, Recently Deleted, Saved voices, Licenses and the model download are pushed routes, as on
  Android; Recording is a full-screen cover. On regular width (iPad, large iPhones in landscape) the Library is a
  sidebar and the note opens beside it (`NavigationSplitView`); on compact width it is one stack. The stack, the
  library search and the Starred filter are saved with the scene and restored on the next launch (not for
  `--ui-testing` launches). Moving a note to Recently Deleted closes it wherever it is open, the detail column
  included.
- **Back labels.** iOS has no system Back. `Router.below(_:)` / `BackStack.below` give the screen under a route, for
  the labels Android picks the same way (`DeepLinksTest#theKeyBelowAScreenPicksItsBackLabel`).
- **Settings storage.** Android keeps its small settings in a DataStore file; iOS keeps them in `UserDefaults` under
  the same key names (`models.consentAt`, `queue.hold`, `notices.recoveredAck`, …; see `SettingsKeys`). Timestamps are
  epoch milliseconds, as on Android. The queue hold is stored as `user` / `system`.
- **Speech-model consent** is a timestamp (`models.consentAt`), as on Android. The old `modelDownloadsAllowed` and
  `speakerDownloadsAllowed` switches migrate to consent at first launch and are then removed.
- **Palette.** The warm iOS palette (paper, card, ink, muted, ember) stays the brand; tone tints (ok, info, warn,
  error, plain) and speaker tints are added in `Cassini/Design/Tokens.swift`. Contrast is checked by WP14.
- **Failure codes.** `JobFailure` stores Android's core `Failure` names (`OPEN`, `LARGE`, … `OPUS_ENCODER`), the
  `DOWNLOAD_` and `DOCUMENT_` codes and `CHECKPOINT_MISMATCH`, plus three iOS-only codes: `INTERRUPTED` (Cassini
  closed during the job), `UNSUPPORTED_LANGUAGE` and `RESERVATION_LIMIT` (Apple's speech assets). Core `DOWNLOAD`,
  `VERIFY` and `INSTALL` are the cases `modelDownload`, `modelVerify` and `modelInstall`, so they don't clash with
  `download(_:)`. `DOWNLOAD_STOPPED_BY_SYSTEM` means iOS ended the background time of the download. `AUDIO` reads
  "Could not read this audio", as on Android, for both a recovered and a just-finished recording.
- **Clock name.** The port is `AppClock`, not `Clock`, because Swift's standard library already has a `Clock`.

## Where things live (for later work packages)

- **Ports** (`Packages/CassiniEngine/Sources/CassiniEngine/Ports`) are frozen. `Transcribing` and `SpeakerAnalyzing`
  report typed events (`TranscriptionEvent`, `SpeakerAnalysisEvent`) rather than strings; the app words them.
  `AudioProcessing` (inspect, compress, decode Opus) was added so file-level audio work stays behind a port.
- **Job interface.** `TranscriptionJobRunning.run(_:stop:events:)` (Engine `Ports/`) takes a `StopSignal`: the
  coordinator asks for `.pause(reason)` or `.cancel`, and the job ends with `JobOutcome.paused(reason)` or
  `.cancelled`. `JobEvent`, `JobOutcome`, `JobStart`, `RestoredCheckpoint`, `DownloadProgress`, `DownloadFailure`
  and `TranscriptionStage` live in CassiniNotebook (`Progress/JobEvent.swift`) so WP5's progress tracker can use them
  there. They mirror Android's `JobTypes.kt` with these differences: draft words are `DraftWord` (Core's `Word` is
  not `Sendable` yet); `JobEvent.draft(words:tentativeFromMs:)` is iOS-only, for Apple's volatile results;
  `JobEvent.ended` is the only `Ended`; Android's `Failed(Download(error, part, requiredFreeBytes))` is
  `JobOutcome.downloadFailed(DownloadFailure)`, stored as `JobFailure.download(error)`. The job calls `events` from
  any thread; the coordinator must apply them through one ordered consumer, as `ProcessingStore` does today.
- **Queue and voices on disk.** `JobRepository` (`jobs.json`, `{version, jobs}` in `seq` order) and the `JobStore`
  actor (enqueue, claimNext, transition, remove) are in place with the Android queue rules that need no note facts;
  WP4 adds the enqueue refusals, reconcile and the coordinator. `VoiceStore` is an actor over `VoiceLibrary`; WP8
  adds the versioned `voices.json`, the corrupt-file rename and moves `VoicesStore` onto it. `PauseReason` has
  Android's `memory`.
- **Notice facts** carry Android's `jobRunning`, `consented` and the download's `requiredFreeBytes`; `LibraryFacts`
  is next to them. Android's `encoderMissing` and `m4a` are not there: the iOS app always has its Opus encoder.
- **Note writes.** `NoteStore` is where concurrent note writes meet. Engine writers (jobs, recording, trash,
  import) call `NoteStore.mutate` directly. `LibraryStore.update`/`commit`/`updateAll` apply a `@Sendable` change to
  the main-actor mirror at once and send it as a `NoteEdit` to `NoteStore.apply(_:)`: when nobody saved the note
  since the edit was made, the edit's result is written as the screens show it; otherwise the change runs again on the
  stored note, so both writes survive. That holds because every change only sets the fields its operation owns and
  never assigns the whole note; speaker analysis and speaker naming build their speakers and matches first and set
  only those, the attribution and the versions inside the change. After a note's last queued edit lands, the mirror
  takes the stored note. Ids and dates a change stamps on the note are made before the change
  (`addBookmark(at:id:)`, `saveCurrentVersion(name:id:date:)`), so running it again gives the same values.
- **Going to the background** holds a background task until every queued note write (the playback position
  included) has landed.
- **Playback interruptions.** The player pauses inside the interruption and route-change observers; `PlaybackStore`
  updates its state from the adapter's event stream right after, one main-actor hop later.
- **Data-only states** are in CassiniNotebook so the pure rules and the widget can use them: `ProcessingState`
  (`Progress/`), `RecordingState` and `RecordingActivityState` (`Recording/`), `PlaybackState` (`Playback/`),
  `NoticeFacts` (`Notices/`).
- **Placeholder coordinators.** Today's queue, recording and playback behaviour runs in the app stores
  `ProcessingStore`, `RecordingStore` and `PlaybackStore` on top of the ports. WP4, WP3 and WP7 build
  `TranscriptionCoordinator`, `RecordingController` and `PlaybackController` in CassiniEngine and make these stores thin.
  Import and export placeholders are `ImportStore` (WP12) and `ExportStore` (WP12/WP13); trash is `TrashStore` (WP2).
- **SettingsStore** is in CassiniEngine (`Stores/SettingsStore.swift`), not the app, so `swift test` covers it; WP10
  owns it from here.
- **Startup.** `Startup` runs hooks in fixed slots: `load`, `recover` (WP3), `reconcile` (WP4), `voiceLinks` (WP8),
  `purge` (WP2), `sweep` (WP13). `AppGraph.registerStartup()` is where each WP adds its hook.
- **Notices.** Until WP9's `NoticeCenter`, `NoticesStore` keeps every message until it is dismissed; a new one never
  replaces another.
- **Live Activity.** `CassiniShared/RecordingActivityAttributes.swift` is compiled into the app and, once WP3 adds it,
  the `CassiniActivity` extension; `LiveActivityIntent`s go in the same folder. `project.yml` changes go through WP0.
- **Test fakes** are in the `CassiniEngineTesting` product. Every source in it is under `#if DEBUG`, so the Release
  app links an empty module; `nm` on a Release simulator build finds no `Fake`, `FixedClock` or
  `CassiniEngineTesting` symbols. The app imports it only in Debug, for UI-test launches. UI-test launches also take
  their default speech language from the pinned en_US locale.
- **UI-test launches.** `--ui-testing` uses its own library folder and preferences suite, a clock fixed at Thursday
  8 October 2026 09:41 UTC, en_US formatting and fake transcription. Named seeds: `--seed library|search|speakers|
  trash|voices|processing|recording` (`--seed-test-data` is `library`); `processing` freezes a job at 62 %, `recording`
  uses a fake microphone. `--open-fixture [note id]` opens the given note, or the newest.
- **Hosted tests** build an `AppGraph` over a temporary root and a fresh `UserDefaults` suite (`CassiniTests/TestGraph.swift`).
