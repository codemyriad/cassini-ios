# WP4 — durable transcription queue: notes for the README and later work packages

## Differences from Android

- **Queue storage.** Android keeps the queue in Room's `jobs` table; iOS keeps it in `<root>/jobs.json`
  (`{version, jobs}` in `seq` order). Every transition is one atomic write of that file, made before the call
  returns; a failed write leaves the queue in memory as it was, so a claim that cannot be saved leaves the job queued
  for the next drain.
- **Where it runs.** `TranscriptionCoordinator` (CassiniEngine) is a `@MainActor @Observable` class. Android's queue
  `Mutex` is a serial main-actor section (`SerialLock`); the job runs off the main actor and its events reach one
  ordered consumer.
- **Background time.** Android runs jobs in a foreground service with an ongoing notification. iOS gives each job a
  `BGContinuedProcessingTask` (identifiers `app.codemyriad.cassini.transcription.<token>`, permitted as
  `app.codemyriad.cassini.transcription.*`): iOS shows "Transcribing “title”" with the job's progress and a Stop button.
  The next job's task is asked for before the previous one ends. iOS grants these only while Cassini is on the screen,
  so a job that starts in the background, or a refused request, falls back to the finite time of
  `beginBackgroundTask`. Expiry and the system Stop do what Android's `onTimeout` does: the job learns of it before the
  handler returns, the queue is held (`system`), the job shows as paused by the system at once, and while Cassini is
  hidden the notification "Transcription paused by iOS · iOS needed the time back. Open Cassini to resume." is posted.
  It carries no "Paused at" numbers. The old behaviour (expiry cancelled every queued job) is gone.
- **Not applicable on iOS:** foreground-service types (`theForegroundNeedFollowsThePhaseAndTheApiLevel`), a refused
  service start (`aRefusedStartBeforeTheStartupWorkEndedStillPostsReadyToTranscribe`), Cancel of a model download inside
  a job and a standalone download stopped by the system (`cancelDuringTheDownloadOfAJob…`,
  `aSystemStopEndsAStandaloneDownloadAndOffersItAgain`: Apple installs its speech assets itself), draft names
  (`aDraftConfirmRacingTheJobsLiveUpdatesLosesNeither`: iOS tells speakers apart after the words), and the sealed
  output with its marker and adopt (`aMarkerWithoutARowIsAdopted` and the other adopt cases: iOS writes the transcript
  atomically to `note.json`). `JobOutcome.adoptPending` is treated as `done`.
- **Enqueue refusals.** Android's `NO_NOTE`, `TRASHED`, `RECORDING` and `UNKNOWN_FORMAT`, plus the iOS-only
  `unplayable` (iOS cannot decode the audio, such as an imported Opus container). There is no `ADOPT_PENDING`.
- **Consent.** As on Android, consent is the recorded `models.consentAt`, or nothing to download: the speech model is
  installed. On iOS a language Apple's model does not offer also counts as nothing to download; the job then fails with
  `UNSUPPORTED_LANGUAGE` rather than waiting for a consent that cannot help. Speakers-only jobs use the separate speaker
  model consent (`speakerModels.consentAt`) or installed speaker models.
- **Status in `note.json`.** The job is the truth, but the coordinator keeps each note's coarse `status` (and the
  failure of a failed job) in step with it, for older readers and for the screens that still read `status`. A note that
  says it was queued or transcribing without any job (a queue from before `jobs.json`) is set back with the failure
  `INTERRUPTED` at launch.
- **The job.** Until the windowed job lands, the app runs `WholeFileTranscriptionJob` (`Cassini/Adapters`): the whole
  file in one pass, the transcript saved as soon as it is complete, then the speakers. It saves no progress, so a
  stopped job is paused with nothing saved and starts from the beginning when resumed, and `WorkDirectories` reports
  no saved progress for any note. The queue, reconcile and the tests already work with saved progress through the
  `JobCheckpoints` port.
- **Held queue.** The Library shows "Transcription paused · N waiting" with Continue while a hold keeps queued notes
  from starting. The queue's facts for the notice rules come from `ProcessingStore.contribute(to:)`.
- **Model download screen.** Android's "Transcribe on this phone" reads "Transcribe on this device" (iPad). iOS does not
  tell the size of Apple's speech assets before they are downloaded, so the screen lists the missing parts without
  sizes, the body has no total, and the free-space check and the "Needs about N free" figure use estimates per part
  (512 MiB for the speech model, 128 MiB for the speaker models). Saved-voice recognition shares the speaker models'
  install, so it is never listed on its own. The screen is a pushed route: Back closes it (no separate Close button).
  Notifications are asked for once, inside the Download step, and the download goes on whatever the answer; Android's
  `theDownloadStartsAfterTheAnswerInANewProcess` does not apply because the iOS prompt does not outlive the app. The
  standalone Download installs Apple's speech assets at once; the speaker models download with the first speaker
  analysis.
- **The flow test** (`ModelDownloadFlowTest`) starts from a note's Transcribe rather than a Settings row, with the
  `--models-missing` launch flag (fake models that are not installed). It checks the sources link opens Licenses, Back
  returns, and "Not now — keep the audio" leaves the note audio only; a second test checks "Download and transcribe".

## Interface changes (for the integrator)

- `JobStore.enqueue(_:kind:language:now:)` takes `language: String?` (nil keeps the job's) and, as on Android, keeps the
  numbers of saved progress when it requeues a stopped job. New: `requeueAtBack(_:kind:language:checkpoint:now:)` (Restore)
  and `replace(_:)` (the launch repair's one write).
- New in `CassiniEngine/Transcription`: `TranscriptionCoordinator`, `Reconcile`, `EnqueueRules` (`StartOrigin`,
  `EnqueueRefusal`, `TranscribeOutcome`, `DequeueOutcome`), the `JobCheckpoints` port with `CheckpointStatus` (the
  windowed job's checkpoint store should conform to it), `ModelConsent`, `ModelPlan`, `ModelDownloadModel` and its
  `ModelDownloadPorts`. Testing fakes: `FakeJobRunner`, `FakeCheckpoints`.
- `AppEnvironment` has a `notifier` (live: `UNNotifier`; UI tests: a `FakeNotifier` that never asks) and the
  `--models-missing` UI-test flag. `ProcessingStore` is now a thin layer over the coordinator: `transcribe(_:kind:origin:)`
  returns the outcome, `request(_:kind:origin:)` fires it, and `moveToTrash`, `restore`, `forget`, `cancel`, `stopAll`,
  `continueQueue`, `startOver`, `clearFailed` and `setVisible` forward to the coordinator. `TrashStore` stores the
  note's `trashedJob` and hands it back on Restore.
- `Info.plist`: `UIBackgroundModes` gains `processing`; `BGTaskSchedulerPermittedIdentifiers` lists
  `app.codemyriad.cassini.transcription.*`.
- Strings: the `Transcription` table (`Cassini/Resources/Strings/Transcription.xcstrings`), English and Italian.
