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
- **App termination.** On `willTerminate` the capture adapter stops the recorder synchronously, so the CAF header is
  written and the next launch recovers a clean file.
- **An empty capture.** As on Android, a capture whose file is empty is discarded; a CAF that holds only its header is
  kept as a 0-second note.

## Finish

- Finish seals the note (plain, duration, final title) and opens it at once; the waveform, the M4A compression and the
  hand-off to transcription follow while the note is shown. The note cannot be queued until its audio is written
  (`RecordingHandoff.audioFinalizing`). When compression fails the CAF stays the recording, a notice says so, and the
  CAF is transcribed.
- A recording longer than 36 h is saved with `failure = LONG` and never queued.
- **Automatic transcription off** (an iOS setting Android does not have) makes every finish audio only.
- A seal that cannot be written leaves the note live on disk; the next launch's recovery makes it plain.

## Recording screen

- The screen is a full-screen cover. Android's process-death restoration (`aRestoredEntryWithoutARecordingClosesItself`)
  does not apply; the cover is not restored with the scene.
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

## Recovery

- Live notes other than the active one get their CAF `data` chunk repaired (`CAFRepair`, CassiniAudio) instead of
  Android's Ogg repair, then become plain with the duration read back, or unplayable ("This recording can't be
  played …"). They are reported oldest first as `NoticeFacts.recovered`; until WP9's notice centre, the Library shows
  "N recordings recovered. Cassini closed unexpectedly. We saved what was captured (…)."
- Leftovers of an unfinished finish are deleted: a `capture.caf` or `audio.m4a` the note does not point at.
- **Rebuild from audio** replaces Android's catalogue rebuild (there is no `document.opus` on iOS): a note directory
  with audio but a missing or undecodable `note.json` gets a note "Recovered recording 8 Oct" (origin recovered),
  before the Library loads; the damaged file is kept as `note.json.corrupt-<ms>`. A `note.json` from a newer Cassini,
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
- `RecordingState.inProgress` was added.
- `AppEnvironment` gained `microphone`, `liveActivity` and `notifier` (nil until WP9's adapter exists).
