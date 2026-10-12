# WP3 — recording, storage policy, recovery, Live Activity: differences from Android

## Capture and storage

- **Format.** iOS captures 48 kHz 16-bit mono linear PCM into `capture.caf` (96,000 B/s) and compresses it to
  `audio.m4a` at Finish; Android captures Opus (or AAC). The format chip reads "PCM 48 kHz".
- **No file-size limit.** CAF has 64-bit chunk sizes and no MP4 index, so Android's 1 GiB AAC limit,
  `FileLimitNear` and `StoppedAtFileLimit` do not exist. Their tests (`anAacFileStopsAtItsLimitAndOnlyThere`,
  `anAacFileStopsAtItsSizeLimitAndSavesTheAudio`) are not ported.
- **The floor counts the finish.** Recording stops one byte below 200 MiB **plus** the room the finish needs for its
  M4A copy (`RecordingPolicy.finishReserve`: 16,000 B per second captured, i.e. AAC at 128 kb/s, above what Apple's
  M4A preset writes for mono speech). The hint and the 15-minute warning count both the capture's growth and the
  reserve's, so "Space for about N h more." is the time until that stop. Android's floor is 200 MiB alone because its
  capture file is the final file.
- **The rate** is nominal (96,000 B/s) for the first 10 s, then the measured growth of the file, as on Android.
- **No wake lock.** iOS keeps a recording alive with the `audio` background mode; the controller has no wake-lock
  renewal (`aRecordingHasNoTimeLimitAndRenewsItsWakeLock` is ported without it).
- **Audio session.** The session does not mix with other apps (no `.mixWithOthers`), so a call interrupts the
  recording, which pauses as "Paused — another app is using audio" and stays paused until the user resumes. When
  resuming fails because the other app still holds the audio, the recording stays paused with that banner.
- **Input lost** (headphones or an external microphone unplugged) is an iOS extra: the recording pauses with "Paused —
  audio input disconnected" and Resume.
- **Media services reset** ends the recording as a microphone failure, saving what was written.
- **App termination.** On `willTerminate` the capture adapter stops the recorder synchronously (without reporting a
  microphone failure), so the CAF header is written; it does not seal the note. The note's rows are written through the
  main-actor `LibraryStore` and the `NoteStore` actor, which a synchronous termination handler cannot wait for, and a
  write that bypasses them could race the writes already queued. The next launch's recovery seals the note instead
  (plain, the duration read back), so a recording ended by swiping Cassini away is reported as "recording recovered"
  rather than finished. This replaces the spec's synchronous finish attempt.
- **An empty capture.** As on Android, a capture whose file is empty is discarded; a CAF that holds only its header is
  kept as a 0-second note.

## Finish

- Finish seals the note (plain, duration, final title) and opens it at once; the waveform, the M4A compression and the
  hand-off to transcription follow while the note is shown. The note cannot be queued until its audio is written
  (`RecordingHandoff.audioFinalizing`). When compression fails the CAF stays the recording, a notice says so, and the
  CAF is transcribed.
- **The hand-off waits for the audio**, where Android hands off inside `end()`. To keep the user's consent through a
  kill during the compression, a note to transcribe is sealed with status `queued`; the next launch's reconcile then
  shows it as interrupted (ready to transcribe again) instead of silently audio only. A hand-off that is refused, or a
  capture that cannot be read, sets it back to audio only. The Finish outcome (`saved(transcribe)`) is reported before
  the hand-off, so a refused hand-off is not reflected in it, where Android reports `AUDIO_ONLY`; on iOS both
  outcomes open the note the same way, and the note's status shows the result.
- A recording longer than 36 h is saved with `failure = LONG` and never queued.
- **Automatic transcription off** (an iOS setting Android does not have) makes every finish audio only.
- **A seal that cannot be written** leaves the note live on disk, and the next launch's recovery makes it plain. For
  the rest of the session the note is shown sealed (plain, audio only, its title and duration) through
  `RecordingNotes.showUnsaved` (`LibraryStore.showUnsaved`), so it opens as a note and not as a recording; the Library
  reports the failed write, nothing is compressed or queued, and the outcome is `saved(audioOnly)`.
- **A title typed while the microphone starts** is kept (`RecordingController.startingTitle`) and written once the
  capture runs, as Android's `Starting(title)`; the frozen `RecordingState.starting` carries no title.

## Recording screen

- The screen is a full-screen cover. Android's process-death restoration (`aRestoredEntryWithoutARecordingClosesItself`)
  does not apply; the cover is not restored with the scene.
- **One model for every showing.** Android's view model belongs to one navigation entry, so its "leaving" latch starts
  fresh each time. The iOS `RecordingScreenModel` lives as long as `RecordingStore`, and the cover is shown from the
  Record button, the Library's card and row, the Live Activity and an automatic stop; the view calls `appeared()` on
  each showing (and an automatic stop resets the latch before `.show`), so each showing leads away once.
- "Mark a moment" bookmarks the capture's current time (`RecordingController.currentElapsed`), not the displayed time,
  which is refreshed once a second.
- **Permissions.** iOS asks for the microphone with the system question when access is undetermined; a denial shows
  "Microphone access is off" with Open settings, and the recording starts when the app becomes active with access
  granted. Notification permission is asked once, at the first recording, after the microphone (Android asks both
  together on API 33+; `belowApi33OnlyTheMicrophoneIsAsked` does not apply).
- **An automatic stop while minimised** (storage, microphone failure) brings the Recording screen back with its banner
  and Open note; Android shows it in the ongoing notification. In the background a result notification ("Recording
  stopped") is posted through the `Notifier` port.
- **Bookmarks** ("Mark a moment") are an iOS extra and stay on the screen.
- The recording banners are a pure rule (`RecordingBanner.banners`, in CassiniNotebook) rendered by the Recording
  screen itself in light tones; WP9's banner catalogue does not cover them.
- The timer's VoiceOver value uses the system's spelled-out duration ("24 minutes, 7 seconds").

## Live Activity

- Android's ongoing recording notification is a Live Activity (Lock Screen and Dynamic Island) with the title, the
  running time (`Text(timerInterval:)`), the paused state, the storage warning and Pause/Resume/Finish buttons
  (`LiveActivityIntent`s in `CassiniShared/RecordingIntents.swift`, compiled into the app and the `CassiniActivity`
  extension). A tap opens `cassini://recording`, which returns to the Recording screen.
- The activity is updated only when what it shows changes (pause, resume, title, warning); the system counts the time.
  Updates and ends reach ActivityKit in the order asked (one chained task).
- **Stale activities.** An activity outlives the process. Every recording activity but the current one is ended
  (`.immediate`) when the adapter is created at launch and at each start, and the end is attempted on `willTerminate`.
  Each button's intent carries the activity's note id, and `RecordingStore` ignores it unless it is the recording in
  progress, so a leftover activity cannot pause or finish another recording.

## Recovery

- Live notes other than the active one get their CAF `data` chunk repaired (`CAFRepair`, CassiniAudio) instead of
  Android's Ogg repair, then become plain with the duration read back, or unplayable ("This recording can't be
  played …"). They are held oldest first in `RecordingStore.recovered`, in the shape of `NoticeFacts.recovered`, for
  WP9's notice centre to publish; until then the Library shows "N recordings recovered. Cassini closed unexpectedly.
  We saved what was captured (…)."
- Leftovers of an unfinished finish are deleted: a `capture.caf` or `audio.m4a` the note does not point at.
- **Rebuild from audio** replaces Android's catalogue rebuild (there is no `document.opus` on iOS): a note directory
  with audio but a missing or undecodable `note.json` gets a note "Recovered recording 8 Oct" (origin recovered),
  before the Library loads; the damaged file is kept as `note.json.corrupt-<ms>`. Rebuilt notes are reported with the
  repaired ones in `RecordingStore.recovered` and the notice. A `note.json` from a newer Cassini,
  or one refused for its content (an unsafe file name), is left alone and counted as unreadable.

## Titles

- New recordings are titled "Voice note 8 Oct, 08:14" (day, short month, 24-hour time, as on Android, in the app's
  language), replacing iOS's "Recording · …". `NoteTitles.recordingDefault` is removed.

## Interfaces changed (frozen in WP0)

- `RecordingOutcome.saved` carries `AfterFinish` (`transcribe`, `askConsent`, `audioOnly`), as Android's
  `Saved(next)`.
- `ActiveRecording.spaceLeft: TimeInterval?` is `space: RecordingSpace?`.
- `RecordingActivityState.warning` is a `RecordingWarning?` (worded by the widget), and `RecordingWarning` is
  `Codable`.
- `LiveActivityPort.start` takes the recording's `noteID`.
- `RecordingNotes` gained `showUnsaved(_:_:)`; `LibraryStore` gained `showUnsaved(_:_:)` (screen-only change).
- `CaptureRecovery.rebuild(in:)` returns `[RecoveredRecording]` (oldest first) instead of `[UUID]`.
- `RecordingIntentRouter.handler` takes the action and the activity's note id; the intents take `noteID`.
- `RecordingState.inProgress` was added.
- `AppEnvironment` gained `microphone`, `liveActivity` and `notifier` (nil until WP9's adapter exists).
