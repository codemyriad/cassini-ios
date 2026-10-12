# WP4 — durable transcription queue: notes for the README and later work packages

## Differences from Android

- **Queue storage.** Android keeps the queue in Room's `jobs` table; iOS keeps it in `<root>/jobs.json`
  (`{version, jobs}` in `seq` order). Every transition is one atomic write of that file, made before the call
  returns; a failed write leaves the queue in memory as it was, so a claim that cannot be saved leaves the job queued
  for the next drain. Room refuses a downgrade on its own; iOS never overwrites a `jobs.json` it cannot read. One
  written by a newer Cassini (its `version` is read before its jobs) is kept as it is and the queue takes no writes in
  this run: Transcribe is refused with `queueUnavailable`. An unreadable one is moved to
  `jobs.json.unreadable-<date>` and the queue starts empty. Either way no `work/` is deleted at launch, notes that said
  they were queued are set back (`INTERRUPTED`), the reconcile step reports the failure to `Startup`, and the
  coordinator keeps it in `loadFailure` for the notice center (WP9) to show. A launch repair that cannot be written
  still applies in memory, so the job that was running is queued again rather than blocking every claim; the next
  write saves it.
- **Where it runs.** `TranscriptionCoordinator` (CassiniEngine) is a `@MainActor @Observable` class. Android's queue
  `Mutex` is a serial main-actor section (`SerialLock`); the job runs off the main actor and its events reach one
  ordered consumer.
- **Background time.** Android runs the drain in a foreground service with an ongoing notification. iOS holds one
  `BGContinuedProcessingTask` for the whole drain (identifier `app.codemyriad.cassini.transcription.queue`, permitted
  as `app.codemyriad.cassini.transcription.*`), asked for at the drain's first claim, which happens from the screen:
  iOS shows "Transcribing “title”" with the running job's progress and a Stop button, and each next job only changes
  its title (`BackgroundRunner.update`) and starts its progress from 0. So a queue left in the background goes on job
  after job. iOS grants these requests only while Cassini is on the screen; a drain that starts in the background, or
  a refused request, falls back to the finite time of `beginBackgroundTask`. Expiry and the system Stop do what
  Android's `onTimeout` does: the job's stop is signalled before iOS's expiration handler returns (on the main thread
  at once, or with a synchronous hop to it), the queue is held (`system`), the job shows as paused by the system at
  once, and while Cassini is hidden the notification "Transcription paused by iOS · iOS needed the time back. Open
  Cassini to resume." is posted. The runner ends the token (`endBackgroundTask`, or `setTaskCompleted(success:
  false)` for the continued task) before iOS's expiration handler returns, exactly once: UIKit terminates an app whose
  finite task is still running after its handler, and Apple documents no time after it, so no grace is kept for
  either path. Only the `system` hold is stored before the handler returns (in `UserDefaults`, which reach `cfprefsd`
  at once); the paused job's write and the notification are started then and may not land before iOS suspends or
  kills Cassini. Android writes the pause inside `onTimeout`; on iOS the launch repair finishes it instead: under the
  stored `system` hold no job is claimed, so a job still `running` in `jobs.json` is the one iOS stopped, and
  `Reconcile` pauses it by the system with the numbers of its saved progress and its attempts unchanged, rather than
  queueing it again as a crash (`ReconcileReport.pausedBySystem`); the notification the kill lost is posted when
  Cassini comes back hidden. A job starts only once the drain's background time is held and carries its title. The paused job takes the numbers of the last saved progress when it ends, but the
  notification carries no "Paused at" numbers (`aSystemStopReachesTheJobAtOnceAndThePausedNoticeGetsTheLastCheckpoint`
  is ported without its notification part). The old behaviour (expiry cancelled every queued job) is gone.
- **On the screen.** Cassini counts as hidden only in `.background`; `.inactive` (Control Center, the app switcher, a
  system alert) keeps it visible, as Android counts the app visible from `ON_START`.
- **Not applicable on iOS:** foreground-service types (`theForegroundNeedFollowsThePhaseAndTheApiLevel`), a refused
  service start (`aRefusedStartBeforeTheStartupWorkEndedStillPostsReadyToTranscribe`), Cancel of a model download inside
  a job and a standalone download stopped by the system (`cancelDuringTheDownloadOfAJob…`,
  `aSystemStopEndsAStandaloneDownloadAndOffersItAgain`: Apple installs its speech assets itself), draft names
  (`aDraftConfirmRacingTheJobsLiveUpdatesLosesNeither`: iOS tells speakers apart after the words), and the sealed
  output with its marker and adopt (`aMarkerWithoutARowIsAdopted` and the other adopt cases: iOS writes the transcript
  atomically to `note.json`). `JobOutcome.adoptPending` is treated as `done`.
- **Enqueue refusals.** Android's `NO_NOTE`, `TRASHED`, `RECORDING` and `UNKNOWN_FORMAT`, plus the iOS-only
  `unplayable` (iOS cannot decode the audio, such as an imported Opus container) and `queueUnavailable` (see Queue
  storage). There is no `ADOPT_PENDING`. The plan's `unverifiedDocument` and `tooLong` refusals are dropped to match
  Android: an unverified document can be transcribed, and audio over 36 h (`Limits.maxTranscribeDuration`) is not
  handed to the queue after a recording or an import (`handOff`, as Android's `RecordingController.next`), while a
  Transcribe of it ends as `LONG` inside the job (WP5). Android only logs a refused Transcribe; the iOS note screen
  shows why (`EnqueueRefusal.message`, Transcription table).
- **Consent.** As on Android, consent is the recorded `models.consentAt`, or nothing to download: the speech model is
  installed. After a recording or an import with Transcribe automatically on, `handOff` follows Android's
  `RecordingController.next`: queued when consented, audio only when the download was declined, otherwise the model
  download screen opens over the note (when the note is still the screen on top; on iOS compression comes first). On iOS a language Apple's model does not offer also counts as nothing to download; the job then fails with
  `UNSUPPORTED_LANGUAGE` rather than waiting for a consent that cannot help. Speakers-only jobs use the separate speaker
  model consent (`speakerModels.consentAt`) or installed speaker models.
- **Status in `note.json`.** The job is the truth, but the coordinator keeps each note's coarse `status` (and the
  failure of a failed job) in step with it, for older readers and for the screens that still read `status`. A note that
  says it was queued or transcribing without any job (a queue from before `jobs.json`) is set back with the failure
  `INTERRUPTED` at launch.
- **The job.** The queue runs WP5's windowed `TranscriptionJob`. The coordinator reads its checkpoints through
  `NoteWorkFolders` (`JobCheckpoints` over `CheckpointFiles`): a checkpoint that cannot be read, or whose audio name or
  `length:mtime` no longer matches the note's file, is a mismatch. It tells `JobProgress` (the Note screen's card and
  the rows) when each job begins, its events and its end, and the system's progress follows `JobProgress`'s percent.
  A transcribe of a note with saved progress keeps the language the checkpoint began in (the job's, else the note's),
  because the checkpoint must match it; the Settings language applies once there is none (Start over). A paused
  transcription posts WP5's "Paused at … of …" notice through `TranscriptionCoordinator.onPause`, except for a note
  going to Recently Deleted and for a speakers-only job. A `CHECKPOINT_MISMATCH` keeps its `work/` until Start over,
  as Android's banner offers (WP5's interim queue dropped it at once).
- **Held queue.** The Library shows "Transcription paused · N waiting" with Continue while a hold keeps queued notes
  from starting. Whether it shows is the pure `ProcessingState.heldWaiting` (tested in CassiniEngine); `QueueHeldBanner`
  only renders it and stands in for the queue-held notice until WP9's notice center renders `NoticeFacts.queueHold`
  and `waitingJobs`, which `ProcessingStore.contribute(to:)` fills. WP9 should then remove the banner.
- **Recently Deleted.** Notes in Recently Deleted are read at launch and kept in step by Trash and Restore; their jobs
  never count as waiting, start a drain or run. Android removes a queued row in the same transaction as the trash;
  iOS removes it in the queue's serial section right after, so the launch repair finishes a trash that Cassini closed
  in the middle of: a queued job of a trashed note is removed and a running one paused by the user, its `work/` kept
  for Restore (`ReconcileReport.trashed`). An Undo that reaches the queue first keeps the job it queued again. When the
  note's trash write is refused, the queue side is undone; a permanent delete waits for a running job to stop and
  removes the job only after the note's files are gone, so a failed delete keeps both.
- **Model download screen.** Android's "Transcribe on this phone" reads "Transcribe on this device" (iPad). iOS does not
  tell the size of Apple's speech assets before they are downloaded, so the screen lists the missing parts without
  sizes, the body has no total, and the free-space check and the "Needs about N free" figure use estimates per part
  (512 MiB for the speech model, 128 MiB for the speaker models). Saved-voice recognition shares the speaker models'
  install, so it is never listed on its own. The screen is a pushed route: Back closes it (no separate Close button).
  Notifications are asked for once, inside the Download step, and the download goes on whatever the answer; Android's
  `theDownloadStartsAfterTheAnswerInANewProcess` does not apply because the iOS prompt does not outlive the app. The
  standalone Download installs Apple's speech assets at once through `Transcribing.installAssets` (CassiniInference);
  its progress and failure are `ProcessingStore.speechInstall`, passed on as `NoticeFacts.download`. Showing them in
  the Settings model rows and the download notice is WP10's and WP9's. The speaker models download with the first
  speaker analysis.
- **Tests not ported as such.** `aFailureAroundTheJobEndsItAndTheQueueGoesOn` is ported as a note write that fails when
  the job ends (iOS has no battery tracker around the job); the claim that cannot be saved has its own test.
  `aQueuedJobWithoutConsentEndsNeedsConsentInTheRealJob` is a hosted test over `WholeFileTranscriptionJob`. The
  acceptance scenario "killed with 3 queued and 1 running" is
  `aKillWithThreeQueuedAndOneRunningJobRunsTheRunningOneFirstThenTheRestInOrder`.
- **The flow test** (`ModelDownloadFlowTest`) starts from a note's Transcribe rather than a Settings row, with the
  `--models-missing` launch flag (fake models that are not installed). It checks the sources link opens Licenses, Back
  returns, and "Not now — keep the audio" leaves the note audio only; a second test checks "Download and transcribe".

## Interface changes (for the integrator)

- `JobStore.enqueue(_:kind:language:now:waitingForConsent:)` takes `language: String?` (nil keeps the job's) and, as on
  Android, keeps the numbers of saved progress when it requeues a stopped job; `waitingForConsent` writes it as
  `needsConsent` in the same write. New: `requeueAtBack(_:kind:language:checkpoint:now:)` (Restore),
  `replace(_:removing:)` (the launch repair's one write), `assume(_:removing:)` (the repair in memory when it cannot be
  written), `load(now:)` with `JobStore.Failure` and `isWritable`. `JobRepository.moveAside(at:)`.
- Ports: `BackgroundRunner.update(_:title:)` (the next job of a drain in the same background time);
  `FakeBackgroundRunner.expireAll()` ends each token right after its handler, before anything the handler started
  runs, as a suspension or kill at that point would; `TranscriptionCoordinator.systemStop()` returns its best-effort
  steps (`@discardableResult`); `Reconcile.plan` takes the stored `hold:` (default nil); and
  `Transcribing.installAssets(locale:progress:)` (the standalone speech model install). Their fakes implement them;
  `FakeTranscriber` now asks for consent like Apple's when its model is not downloaded and the request may not
  download it, and `FakeCheckpoints` can hold a note's status read.
- `TranscriptionCoordinator.handOff(_:) -> HandOff` and `loadFailure`; `EnqueueRefusal.queueUnavailable`;
  `ProcessingState.heldWaiting`; `ReconcileReport.trashed` and `Reconcile.Plan.removeJobs`. `Router.offerModelDownload(for:)`.
- New in `CassiniEngine/Transcription`: `TranscriptionCoordinator`, `Reconcile`, `EnqueueRules` (`StartOrigin`,
  `EnqueueRefusal`, `TranscribeOutcome`, `DequeueOutcome`), the `JobCheckpoints` port with `CheckpointStatus` (the
  windowed job's checkpoint store should conform to it), `ModelConsent`, `ModelPlan`, `ModelDownloadModel` and its
  `ModelDownloadPorts`. Testing fakes: `FakeJobRunner`, `FakeCheckpoints`.
- `AppEnvironment` has a `notifier` (live: `SilentNotifier`, a stand-in that never asks and posts nothing until WP9's
  `UNNotifier` replaces it, with the copy of every kind in WP9's `Notices` table; UI tests: a `FakeNotifier` that
  never asks) and the `--models-missing` UI-test flag. `ProcessingStore` is now a thin layer over the coordinator: `transcribe(_:kind:origin:)`
  returns the outcome, `request(_:kind:origin:)` fires it, and `moveToTrash`, `restore`, `forget`, `cancel`, `stopAll`,
  `continueQueue`, `startOver`, `clearFailed` and `setVisible` forward to the coordinator; `handOff`, `stopForDelete`,
  `installSpeechModel(language:)` and `speechInstall` are new, and its init takes the transcriber and the clock. `TrashStore` stores the
  note's `trashedJob` and hands it back on Restore.
- `Info.plist`: `UIBackgroundModes` gains `processing`; `BGTaskSchedulerPermittedIdentifiers` lists
  `app.codemyriad.cassini.transcription.*`.
- Strings: the `Transcription` table (`Cassini/Resources/Strings/Transcription.xcstrings`), English and Italian.
- Integration with WP3, WP5 and WP12 (phase-b): `TranscriptionCoordinator.Parts.progress` (WP5's `JobProgress`),
  `TranscriptionCoordinator.onPause` and `waitForJob(of:)`; `NoteWorkFolders` (`JobCheckpoints` over WP5's
  `CheckpointFiles`) replaces `WorkDirectories`, and `TranscriptionJob` replaces `WholeFileTranscriptionJob`.
  `RecordingHandoff.handOff(_:)` is async and `RecordingController.Parts.consent` takes the queue's `ModelConsent`, so
  a finished recording follows the same consent rule (`ProcessingHandoff` adapts `ProcessingStore`). `ProcessingStore`
  keeps WP5's `progress`, `hasSavedProgress(_:)`, `stop(_:)`, `dequeue(_:)` and paused notices, takes the place of
  `cancel(_:)` with `stop(_:)`, and `trash(_:then:)` writes the trash only once the running job has ended.
  `Transcribing.installAssets` throws `TranscriptionError.failed(.download(_))`. An import with Transcribe
  automatically on goes through `handOff`.
