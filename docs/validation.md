# Validation

The automated checks below run on an Apple Silicon Mac with Xcode 27 and the iOS 27 simulators (iPhone 17 and iPad
Pro 13-inch (M5)). The counts were taken on 13 October 2026 with `scripts/test.sh all`, from the logs in
`DerivedData.noindex/test-logs`. A real device is still needed for the checks in the
[device checklist](#device-checklist).

## Automated checks

`scripts/test.sh` runs the tiers. The modules are targets of the one root `Package.swift`, so every `swift test`
command below runs from the repository root, not from a folder under `Packages/`. Its header lists the options, and the [README](../README.md#verify) summarises them.

| Tier | What runs | Count |
|---|---|---|
| `fast` | `scripts/check-strings.sh`, then `swift test` over the packages | 1,095 tests: 1,086 Swift Testing tests in 155 suites and 9 XCTest cases; the real-model test is skipped unless enabled |
| `app` | The hosted unit tests (`CassiniTests`) in the app on a simulator | 73 |
| `ui` | The UI tests (`CassiniUITests`) on up to three iPhone clones, and the `testIPad*` tests on an iPad clone | 84 test methods: 65 run on the iPhones, the 8 `testIPad*` tests on the iPad, and the 11 `ScreenshotTests` skip |
| `all` | All three; the package tests run beside the build | |

### `fast`: the string catalogs and the package tests

- **String catalogs.** `scripts/check-strings.sh` covers the string tables and the permission prompts
  (`InfoPlist.xcstrings`). It fails on:
  - an Italian, French, Spanish, Brazilian or European Portuguese value that is missing, new, `needs_review` or empty;
  - a plural without exactly its language's CLDR categories;
  - arguments that differ from the English in number or type. A translation may reorder them with `%1$@`. A `one` form
    may drop the count only where `one` means 1 alone, which excludes French and Brazilian Portuguese, where it also
    covers 0;
  - a translation that drops "Cassini";
  - stale or missing keys, and any literal on screen that is not in a table.
- **CassiniCore** (85). The format's own tests, and the published cassini-format conformance vectors. Set
  `CASSINI_CONFORMANCE` to a checkout's `spec/conformance`, or keep `../cassini-format` beside the repository, which
  `scripts/test.sh` finds. With `CASSINI_CONFORMANCE_REQUIRED=1`, which `scripts/test-remote.sh` sets, missing vectors
  fail the run instead of being skipped.
- **CassiniNotebook** (502). The pure rules ported from Android's `:core` and view-model tests: search, previews, day groups
  and row statuses; the Note screen's modes, state, follow and draft rules; transcript turns and tints; banners and
  notice facts; progress, battery projection, checkpoints (including Android's checkpoint golden) and memory
  preflight; recording policy and banners; speaker attribution, naming, matching and saved voices; trash arithmetic;
  the TXT, SRT and WebVTT exports byte for byte against Android's goldens; the note schema and its migration; durable
  writes.
- **CassiniEngine** (462, and 9 XCTest cases). The stores, coordinators and screen models over fakes of every port:
  the transcription queue (enqueue and admission rules, drain, hand-off, background time, cancel, launch reconcile,
  trash), the transcription job (windows, checkpoints, resume, refusals, speaker step), recording (capture, storage
  floor, finish, recovery, the screen model), the Note screen and Name a speaker models, saved voices and naming over
  real files, playback, trash and purge order, notices, import and export, model installs and consent, settings and
  licences, navigation and deep links.
- **CassiniInference**. The file reader behind both transcribers, `ParakeetTranscriber` over a fake native runtime
  (windows on the inference thread, the detector and its fetch only online, the detector's high-passed input across
  windows and after a resume, consent and install, the pinned sizes and marker, memory, resume, cancel), the speaker
  model installer and manifest, the licence assets, and the opt-in real-model test (below).
  `CassiniTests/ParakeetJobTests` runs a real Ultra job on the simulator through `scripts/sherpa-bench.sh`, and
  `CassiniTests/DCVectorTests` runs D26.1's shared DC vector through the real detector and Ultra (it needs the
  coordination checkout's `ux-draft`, or `CASSINI_DC_VECTOR`).
- **CassiniAudio** (12). CAF repair, Opus encode and decode, a portable document written over the app's own Opus, and
  the waveform's AC level.

### `app`: the hosted tests

The app's adapters and composition, in the app on a simulator, over an `AppGraph` with a temporary library
(`CassiniTests/TestGraph.swift`): the real audio pipeline (CAF inspection, M4A compression, import integrity, malformed
audio, recovery), the graph's launch work, the Library over a thousand notes, playback through the app's player,
recording, trash, a speaker analysis racing Forget everyone, notifications and deep links, the date forms, notices, exports and the share sheet's files, the Router,
the rendering of a three-hour transcript, the copy of every banner, and `ContrastTests`, which checks every colour pair
a screen draws in light and dark.

### `ui`: the UI tests

End to end on the simulator, through UI-test launches with named seeds, a fixed clock and fake transcription (see the
[README](../README.md#verify)):

- the Library's row statuses, search, the capture bar and the activity banner (`LibraryUITests`);
- the Note screen: paragraphs, word taps, follow playback, in-note search, the read-only gate, the draft that follows
  its end, Document info, and Cancel during a download (`NoteScreenTests`);
- flows ported from Android: `NoteFlowTests` (transcribe, read, seek, versions, exports), `AcceptanceWalkTests`
  (record, transcribe, read, name, export, trash, restore), `SpeakerNamingFlowTests`, `ModelDownloadFlowTests`,
  `SettingsFlowTests`, recording, trash and undo (`CassiniUITests`);
- the text limits (`TextLimitTests`), the accessibility audits, including clipping at the AX5 text size
  (`AccessibilityAuditTests`), and wide windows on iPad (`WideScreenTests`).

`ScreenshotTests` skips in these runs. `scripts/screenshots.sh` runs it (see the README).

### Real-model check (opt-in)

`CassiniTests/SpeakerJobTests` runs a real job with Parakeet Ultra, streaming Sortformer and CAM++ on the arm64
simulator, over a two-speaker FLEURS mix (A, B, A). It tells the speakers apart window by window, saves A as a voice
from its CAM++ print, and checks that Transcribe again names A with Android's thresholds. It is skipped unless the
build links the native runtime and the environment names the models and the mix; `scripts/speaker-smoke.sh` fetches
both and runs it with `CassiniTests/SpeakerSmokeTests`, which check the wrappers on their own. This is a smoke test of
real inference, not a diarization-error-rate benchmark or a voice-matching calibration. Model weights and recordings
are never committed.

```sh
scripts/speaker-smoke.sh
```

### Release build

An unsigned Release build for a generic device checks that the app builds without the Debug-only fakes:

```sh
xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Device checklist

The simulator has no microphone, no Apple speech models of its own, no Live Activities on a Lock Screen, and no
background limits like a device's. Run these checks on a physical iPhone (and an iPad for the split view) with iOS 26
or later, with Live Activities and notifications allowed. Android's `device-kill-resume.sh` covers the same ground as
the kill-and-resume items.

### Live Activity

- Record, then lock the phone. The Lock Screen shows the recording with its running time. Pause from the Lock Screen:
  the time stops and the button becomes Resume. Resume, then Finish from the Lock Screen: the note opens in Cassini
  with the audio saved.
- The Dynamic Island shows the recording, and a tap returns to the Recording screen.
- Minimise a recording, return through the Library's card and through the Live Activity, then minimise and finish
  from there. Each path leads back to the Library or opens the note.
- Kill Cassini while recording (Xcode's Stop), relaunch and start a new recording. Only the new recording's Live
  Activity shows, and an old one's Pause and Finish do nothing to the new recording.

### Long background capture

- Record for an hour with the screen locked and other apps in use. The recording keeps its full length, and the
  waveform and duration match.
- Fill the storage to about 15 minutes of recording above the floor. The warning shows, then the recording stops and
  saves at the floor without transcribing.
- Receive a phone call while recording. The recording pauses with "Paused — another app is using audio" and stays
  paused after the call until you resume it.

### Background transcription (`BGContinuedProcessingTask`)

- Queue three notes from the screen, then leave Cassini. The system shows "Transcribing “title”" with progress and
  Stop, and the title changes for each next note. All three finish in the background.
- Press the system's Stop. The job pauses by the system, the queue is held, and the notification "Transcription
  paused by iOS" offers Resume. Resume continues from the checkpoint, not from the start.
- Start a transcription while Cassini is already in the background (an import from another app). It gets only the
  short background time, and when that ends the job pauses with its progress kept.

### Kill and resume

- Kill Cassini from the app switcher at about 50 % of a long transcription, then relaunch. The note shows paused
  progress, and Resume continues from the last checkpoint (at most 30 seconds of audio earlier).
- Kill Cassini while recording, then relaunch. The recording is listed with a playable duration, and the "recording
  recovered" notice shows. The Live Activity is gone, at the latest once Cassini has relaunched.
- Kill Cassini with three notes queued and one running. After relaunch the running one resumes first, then the others
  in order.

### Notifications

- With Cassini in the background, a finished transcription posts "Transcribed: <title>", and a failure posts
  "Couldn’t transcribe <title>". A tap opens the note, also from a cold start.
- With previews hidden (Settings › Notifications › Show Previews › Never), the Lock Screen shows "A note was
  transcribed" and never the title.
- Deny notifications in Settings. The "Notifications are off" banner shows in Settings, and Turn on opens Cassini's
  notification settings.

### Bluetooth and audio routes

- Record through AirPods, then take them out. The recording pauses with "Paused — audio input disconnected" and
  resumes on the built-in microphone only when you resume it.
- Unplug wired headphones while recording through their microphone. The recording pauses with the same banner.
- Play a note through a Bluetooth speaker and turn the speaker off. Playback pauses and does not resume by itself.
  The lock-screen and headphone controls play, pause and skip 10 seconds.

### Recognition and speakers

- Download the speech model for English and for Italian from the model download screen, then transcribe in flight
  mode. Check the words of a real conversation by ear.
- Transcribe a meeting with three or four people, with speaker identification on. Check that the speakers are told
  apart, name them, and check that a later recording of the same people gets "Is this …?" suggestions and no false
  ones.
- Turn on automatic naming and record the same people again. Review the names it gives.
- Watch a one-hour transcription for heat and battery use, and check the "Battery at finish" projection.
- On iPad, check the split view in both orientations, and run a transcription while multitasking.
