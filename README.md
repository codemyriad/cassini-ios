# Cassini for iOS

Cassini records audio and makes the transcript on your iPhone or iPad. It labels the speakers and can remember the
voices of the people you name. Search, playback and export all work on the device, with no account and no server.

This is the iOS port of [Cassini for Android](https://github.com/codemyriad/cassini-android/tree/rebuild) (branch
`rebuild`). It ports Android's behaviour and keeps Android's tests: each ported test is marked `// ports:
<AndroidTest>#<name>`. Where the two apps disagree, Android's behaviour wins, unless the difference is an iOS-only
extra or a platform constraint. [Differences from Android](#differences-from-android) lists what remains different and
why. The app is native SwiftUI for iOS 18 or later. On iOS 26 and later it can fall back to Apple's speech model and
uses continued background processing; below iOS 26 it does without both ([iOS 18](docs/ios18.md)). On iOS 18 the
full test leg has passed on the iOS 18.2 simulator, and Whistle has run on two iOS 18 devices (an iPhone 11 and an
iPhone 15, in AWS Device Farm); the finite background path has been checked once by hand on the iOS 18.2 simulator,
and A12 or A10 devices on iOS 18 are not yet verified.

## Screenshots

These screenshots come from the iOS simulator (iPhone 17 and iPad Pro 13-inch (M5)). They were taken by
`scripts/screenshots.sh` from seeded test notes with silent audio and fake transcription, so they are examples of the
interface, not recognition results.

| | Notes | Read and listen | Transcribing | Name a speaker | Settings |
|---|---|---|---|---|---|
| Light | <img src="docs/screenshots/light/01-library.png" width="150" alt="Notes, light theme"> | <img src="docs/screenshots/light/02-read-and-listen.png" width="150" alt="Read and listen, light theme"> | <img src="docs/screenshots/light/03-transcribing.png" width="150" alt="Transcribing, light theme"> | <img src="docs/screenshots/light/04-name-a-speaker.png" width="150" alt="Name a speaker, light theme"> | <img src="docs/screenshots/light/05-settings.png" width="150" alt="Settings, light theme"> |
| Dark | <img src="docs/screenshots/dark/01-library.png" width="150" alt="Notes, dark theme"> | <img src="docs/screenshots/dark/02-read-and-listen.png" width="150" alt="Read and listen, dark theme"> | <img src="docs/screenshots/dark/03-transcribing.png" width="150" alt="Transcribing, dark theme"> | <img src="docs/screenshots/dark/04-name-a-speaker.png" width="150" alt="Name a speaker, dark theme"> | <img src="docs/screenshots/dark/05-settings.png" width="150" alt="Settings, dark theme"> |

The screens that only iOS has, or that look different on iOS:

| | Recording | Search | Recently Deleted | Saved voices |
|---|---|---|---|---|
| Light | <img src="docs/screenshots/light/06-recording.png" width="150" alt="Recording, light theme"> | <img src="docs/screenshots/light/07-search.png" width="150" alt="Search, light theme"> | <img src="docs/screenshots/light/08-recently-deleted.png" width="150" alt="Recently Deleted, light theme"> | <img src="docs/screenshots/light/09-saved-voices.png" width="150" alt="Saved voices, light theme"> |
| Dark | <img src="docs/screenshots/dark/06-recording.png" width="150" alt="Recording, dark theme"> | <img src="docs/screenshots/dark/07-search.png" width="150" alt="Search, dark theme"> | <img src="docs/screenshots/dark/08-recently-deleted.png" width="150" alt="Recently Deleted, dark theme"> | <img src="docs/screenshots/dark/09-saved-voices.png" width="150" alt="Saved voices, dark theme"> |

On iPad the Library stays beside the note, in landscape and in portrait:

<img src="docs/screenshots/ipad/light/01-split-landscape.png" width="480" alt="iPad split view in landscape, light theme"> <img src="docs/screenshots/ipad/dark/02-split-portrait.png" width="270" alt="iPad split view in portrait, dark theme">

<img src="docs/screenshots/ipad/dark/01-split-landscape.png" width="480" alt="iPad split view in landscape, dark theme"> <img src="docs/screenshots/ipad/light/02-split-portrait.png" width="270" alt="iPad split view in portrait, light theme">

## Privacy

Speech recognition and speaker analysis run on the device. Cassini does not upload audio, transcripts or
voiceprints. It has no accounts, no analytics and no advertising. The network is used only to download models, and
only after you agree: Parakeet Ultra and every other model only from Cassini's model host, `dist.gocassini.com`,
through its manifest (D4, D53.1), and, on iOS 26 or later on a device that uses Apple Speech, Apple's speech model
for your language.
Voiceprints
stay in the app's private storage, are excluded from backups, and are never written into a document or an export.
System backups may include recordings and transcripts.

The build bundles pinned Whistle weights and a private Needle runtime (D75.2). Whistle transcribes immediately
without a speech-model download. On supported devices, a calm, dismissible suggestion offers the more accurate
Parakeet Ultra with its actual pinned download size. Once Parakeet is installed and hash-verified, new jobs use it
automatically; Whistle remains selectable. Devices below Parakeet's capability/memory/disk requirements never see
the suggestion. Existing queued and paused jobs keep their recognizer. See [Whistle/README.md](Whistle/README.md)
for the documented minos27 archive exception (linked for iOS 18.0), the iOS 26 and iOS 18.2 simulator parity, the
A12/3GB measurements (made with the 26.0-linked framework; owed again for the 18.0-linked one), and what the iOS 18 evidence does not show (two AWS Device Farm runs on 2026-11-10, iPhone 11 on iOS 18.6.2 and iPhone 15 on iOS 18.0, ran Whistle in a Debug build; no A12 or A10 device on iOS 18 has run it). Internal TestFlight builds
retain private memory diagnostics and must export with testFlightInternalTestingOnly=true.

## Run

You need Xcode 26 or newer (the project is developed with Xcode 27), Swift 6.2 or newer, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated and is not checked in. Generate it
after checkout, and again after changing the targets or adding files:

```sh
brew install xcodegen
xcodegen generate
```

Open `Cassini.xcodeproj`, select the **Cassini** scheme, and run it on an iPhone or iPad simulator or device. For a
device, choose your development team under Signing & Capabilities. No API keys or backend are needed. The pinned Swift
packages are Zstandard (it unpacks the compressed speaker model) and swift-opus (libopus), and `Package.resolved`
records their exact revisions.

## What works

- **Record** with pause and resume, a live waveform, an editable title and "Mark a moment" bookmarks. Recording
  continues with the screen locked or in another app. A Live Activity on the Lock Screen and in the Dynamic Island
  shows the time and has Pause, Resume and Finish. A call or a disconnected microphone pauses the recording until you
  resume it.
- **Safe capture.** Audio is captured as 48 kHz PCM (CAF), which survives a crash, and compressed to M4A at Finish. If
  compression fails, the original stays playable. The recording stops and saves before storage runs out, with a
  warning about 15 minutes before. At launch, recordings that were interrupted are repaired and listed as recovered.
- **Import** any audio format that iOS reads, plus Ogg Opus and Cassini `.opus` documents, from Files (several files
  at once) or with "Open in Cassini" from another app. A file that is already in the library is not added twice. A
  Cassini document's verified transcripts are imported with it.
- **Transcribe on the device** with the bundled Whistle model at once, or with Parakeet Ultra after a one-time download
  of about 531 MB (Ultra, its speech detector and the speaker models, from Cassini's model host) on devices with at
  least 5 GiB of memory. On iOS 26 or later, where neither Whistle nor a verified Parakeet can run, Cassini uses Apple's
  `SpeechAnalyzer` after a model download for the speech language you choose; iOS 18 has no Apple speech, so a device
  that can run neither engine cannot transcribe there ([iOS 18](docs/ios18.md)). The queue is durable: jobs run one at a
  time and survive a relaunch. Progress is saved every 30 seconds of audio, so "Stop and keep progress", iOS taking the
  background time back, or a crash all resume from the last checkpoint. The progress card shows the stages, the percent,
  the time left, a battery projection and the draft so far. On iOS 26 or later transcription continues in the background
  with a system progress indicator; on iOS 18 it pauses when iOS ends the short background time (seen once on the iOS 18.2
  simulator, not on a device). A notification says when a note is done or iOS paused it.
- **Speakers.** As Android does, streaming Sortformer tells the speakers apart window by window while the words are
  decoded, and CAM++ makes a voiceprint for each speaker. The draft shows the speakers as they appear: you can name or
  merge them before the job is done, and a saved voice is suggested in the draft ("Is this Luca?"). Afterwards you
  can name a speaker across all their passages, play a sample of their voice, merge two speakers, or reassign a
  passage.
- **Saved voices.** Cassini can remember a named voice, suggest it in later notes ("Is this Sam Rivera?"), and keep
  names over a Transcribe again. Automatic naming is optional and off by default. You can rename or forget a saved
  voice, forget everyone, or erase all voice data.
- **Read and listen.** The playing word is highlighted, and tapping a word plays from there. You can skip 10 seconds
  back or forward, change the speed, and use the lock-screen and headphone controls. The playback position is kept
  across launches.
- **Search** titles, transcripts and bookmarks, ignoring case and accents, with the matches highlighted. Search inside
  a note shows a "1 of 3" counter. You can star notes and filter by star.
- **Edit and versions.** You can edit a passage's text; its word timing is dropped, but its place in the audio is
  kept. Every transcription, merge and run of edits keeps the transcript from before it as a version you can go back
  to.
- **Export** text, SRT or WebVTT subtitles, structured JSON, a copy of the original audio, or a portable Cassini
  `.opus` document. The document keeps the source's verified transcripts, its private `x` data and its audio packets,
  adds the note's versions and speaker names, and records how each transcript was made. A stale or unverified source
  with nothing new on the device is shared as it is, without a renamed title; one transcribed again keeps only the new
  versions, beside the source's private data and meeting details.
- **Recently Deleted.** Deleted notes stay for 30 days, with Undo right after the delete, and can be restored,
  deleted now, or emptied all at once. A permanent delete also removes that note's voice samples.
- **Settings** for the app language (in the Settings app), the speech language (Apple Speech devices on iOS 26 or later only),
  automatic transcription, speaker identification and automatic naming. The on-device model rows show their status,
  with Download and Cancel. Your library's totals and the licences are there too.
- **Six languages:** English, Italian, French, Spanish, and Brazilian and European Portuguese (D50).
  - Cassini follows the system's language. A regional variant reads as its language (fr-CA as French), and a bare
    `pt` as Brazilian Portuguese. pt-PT and the other Portuguese regions read as European Portuguese, and any other
    language as English.
  - Light and dark appearance, Dynamic Type up to the largest accessibility sizes, VoiceOver, and a split view on iPad
    and on large iPhones in landscape.

## Current boundaries

This is a working iOS app, not yet an App Store release. [Distribution](docs/distribution.md) lists what signing and
TestFlight still need.

- Recognition quality depends on the engine (Whistle, Parakeet Ultra or, on iOS 26 or later, Apple's), the device and the
  language. The simulator screenshots and tests use fake transcription, so they say nothing about accuracy.
- The speaker pipeline's memory needs (Ultra and Sortformer loaded together) have been measured on the simulator only.
  Review automatically named speakers.
- iOS 26 grants continued background processing only to a drain that starts while Cassini is on the screen. Otherwise,
  and always on iOS 18, transcription gets the short background time iOS allows. When iOS ends that time, the job
  pauses with its progress kept, and resumes when you continue.
- Opus playback supports standard mono and stereo files (channel mapping 0). For other files the transcript stays
  readable and the original is kept, with an explanation in place of the player.
- On a device that uses Apple Speech (iOS 26 or later), Apple manages its speech models. iOS does not report their size before the
  download, so the download screen and Settings use an estimate there.
- The build carries what App Store Connect asks for: privacy manifests for the app and the Live Activity extension,
  `ITSAppUsesNonExemptEncryption` set to false, and the increased-memory-limit entitlement. The App Privacy answers
  are "Data Not Collected" with no tracking. The privacy policy is published at https://cassini.talk/privacy/ios/
  from `Privacy.txt` ([distribution](docs/distribution.md#app-store-connect-answers)).
- A real device is still needed to validate recognition, model downloads, long background capture and transcription,
  Bluetooth routes, the Live Activity and thermal behaviour. [Validation](docs/validation.md) has the checklist.
- iOS 18 support rests on the code, unit tests and runs with the iOS 18 facts on the iOS 26 and 27 simulators, and on
  the iOS 18.2 simulator (the iOS 18 test runtime; Apple no longer offers 18.6): there Whistle's imports and parity
  fixtures check out, and on 10 November 2026 the full iOS 18 leg passed (hosted 98/98, iPhone 102/102, iPad 12/12).
  That day two AWS Device Farm runs (iPhone 11 on iOS 18.6.2, iPhone 15 on iOS 18.0) ran hosted Whistle and platform
  tests on devices in a Debug build. No A12 or A10 device on iOS 18 and no Release or TestFlight build at 18.0 has run
  the app. [iOS 18](docs/ios18.md) lists what is shown and what is pending.

## Differences from Android

[docs/differences.md](docs/differences.md) describes each difference in detail. In summary:

- **Unknown meeting dates (D95).** The Library names the group with the shared “Date unknown” heading in all six
  languages, including for VoiceOver. iOS omits the repeated unknown-date label from individual row metadata,
  the Note subtitle and the Document info Recorded row; the Note subtitle keeps the duration. Android repeats
  “Date unknown” on those surfaces. Neither app displays a document's sealing or import time as its recording date.
- **Engines and thresholds.** D78 starts with bundled Whistle and promotes Parakeet Ultra after its pinned files
  are verified. Parakeet needs at least 5 GiB physical RAM (the existing provisional rule) and the normal runtime
  memory preflight; its download suggestion also checks the pinned install's actual disk requirement. Whistle's
  production pipeline and default-limit A12/3GB memory gate passed. On iOS 26 or later Apple Speech remains a
  separately checked fallback candidate when neither bundled nor verified downloaded speech is available; unsupported
  devices/locales are refused before queueing or download consent. On iOS 18 there is no Apple Speech: where Whistle
  cannot run, a Transcribe leads to the Parakeet download consent as on Android, or is refused when the device cannot
  hold Parakeet either. Recording, playback and audio export remain available.
  Apple's distributed Mach-O runtime may be encrypted: iOS pins its clear runtime at build/export and relies on
  the iOS signed-code loader for the installed private framework, with full weights/VAD hashes still checked
  on-device. This distribution constraint differs from Android's ELF packaging; see [Whistle/README.md](Whistle/README.md).
  Speakers
  use Android's streaming Sortformer and CAM++ with Android's thresholds (0.72 automatic, 0.50 suggest, 0.08 margin,
  4 s of speech), so the voiceprints are Android's; voices saved by earlier iOS builds are named again. iOS keeps
  automatic naming off by default. On Apple Speech devices (iOS 26 or later) the speech language is chosen in Settings, because
  Apple's models are per language. The pinned model catalog, plan, redirect policy, fetcher and installer are ported
  with Android's tests, behind an `HTTPTransport` port over a data-task `URLSession` that never follows a redirect
  itself, and one shared installer downloads Ultra, its speech detector and the speaker models with consent. Sizes
  follow the shared rule of the format vectors ("444 MB"), where Android still rounds to tens.
- **Storage model.** A note is a `note.json` beside its audio. The portable Cassini document is sealed only at export,
  with the run's provenance under Android's keys. Each variant carries the language of the run that made its words
  (D53.2): `und` for Parakeet, as Android writes, the locale that ran for Apple Speech, never the Settings language.
  Words that no speaker step told apart are one speaker with an id new to the run (`<run prefix>1`, Android's
  `diar_<run>_1`), labelled "Speaker 1" in the app's language (D59). A passage the user set to no speaker is sealed
  as the speaker `unassigned`, labelled "Unknown speaker" in the app's language (D47); Android's words always have a
  speaker. The cross-app vectors are checked through the reader and the import. Android keeps the transcript in a
  sealed document and a Room catalogue. The queue is `jobs.json`, and checkpoints use iOS's own format. Search
  uses an in-memory index instead of FTS4. Saved voices keep one sample per note instead of a running mean.
- **Transcript rendering (D84).** The pure `CassiniNotebook.TurnModel` ports the gocassini viewer pipeline at
  `1111155cb0017b47c072a8662c54f28ad7c44223`: readable grouping, display-only timing repair, continuity-based
  turn reconstruction, inline interjections, competing-speaker labels and continuation headers. The sealed note,
  live draft, reader, Library previews, search excerpts and text export use that projection. Canonical words and
  timestamps stay unchanged; playback and editing keep the original word indices even when reading order differs.
  The six shared vectors in `CassiniNotebookTests/Resources/interjections` are copied unchanged from coordination
  and checked with `swift test --filter CassiniNotebookTests` (no simulator or e2e). This viewer contract supersedes
  the older per-app paragraph rules, including iOS's former 200/120-word paragraph limits. SRT/VTT retain their
  subtitle cue rules; portable `.opus`/JSON exports retain canonical word order.
- **Recording.** iOS captures PCM CAF and compresses it to M4A, so there is no 1 GiB AAC limit, and the storage floor
  includes the room for that compression. The audio session does not mix with other apps, so a call pauses the
  recording. Losing the input pauses it too. A Live Activity replaces Android's ongoing notification, and recovery
  repairs CAF files.
- **Transcription.** A Parakeet run tells speakers apart as it decodes, as on Android. On the Apple Speech fallback,
  and for Identify speakers, the same streaming pipeline runs over the whole file after the words, so that draft has
  one voice.
  Android's foreground service becomes a `BGContinuedProcessingTask` on iOS 26, and the finite `beginBackgroundTask`
  time on iOS 18, which has no continued processing. When iOS takes the time back, the queue is held and "Paused by
  iOS" is shown. The stepper reads Words, then Speakers & matching.
- **iOS 18** (a platform constraint; [iOS 18](docs/ios18.md)). No Apple Speech and no continued processing: a
  transcription or a standalone model download that is still running about 30 s after Cassini leaves the screen stops
  (the job pauses with its checkpoint, the download keeps its bytes), where Android keeps both running. The paused
  transcription resumes from its checkpoint when Cassini comes back to the screen (a proposal; Android's system pause
  waits for Resume); the download needs Try again. Whistle also needs Armv8.1 atomics and Armv8.3 RCpc, so the A10 iPad (7th generation) gets no
  Whistle; with less than 5 GiB it gets no engine at all. The Whistle binary is built for iOS 27 and linked at 18.0
  under the D75.2 exception as extended, which rests on the iOS 18.2 simulator evidence in
  [Whistle/README.md](Whistle/README.md) and two AWS Device Farm runs on 2026-11-10 (iPhone 11 on iOS 18.6.2, iPhone
  15 on iOS 18.0); no A12 or A10 device on iOS 18 has run it. The transcription's background pause was checked by
  hand on the iOS 18.2 simulator (see [iOS 18](docs/ios18.md)); the download's stop was not.
- **iOS extras.** Stars, bookmarks, playback speed, lock-screen controls, passage editing, JSON export, the Speakers
  list, the "Recently Deleted" name, "Forget all voice data", and Settings sections for transcription, speakers and
  your library.
- **Platform.** The app language is set in the Settings app. iOS has no system Back, so the back button carries the
  title of the screen below. The iPad has a split view. Rename is a sheet. Notifications are silent results with
  hidden-preview text. The warm iOS palette and system fonts stay, with contrast checked by tests. Content width is
  capped at Android's 560 pt. The App Store build declares its privacy manifests, export compliance and memory
  entitlement.

## Verify

```sh
scripts/test.sh fast     # the string catalog check (scripts/check-strings.sh), then the Swift package tests
scripts/test.sh app      # build for testing, then the hosted unit tests (CassiniTests)
scripts/test.sh ui       # build for testing, then the UI tests, sharded across simulator clones
scripts/test.sh all      # all of the above (the package tests run beside the build); prints the time of each step
scripts/test.sh changed  # only what the changes since origin/main touch (or since a base: changed <ref>)
scripts/test.sh build    # only build for testing
scripts/test.sh ios18    # build for testing, then only the iOS 18 leg (below)
scripts/test.sh clean    # delete this worktree's simulator clones
```

The script builds once into `DerivedData.noindex` and runs the tests from that build. It clones the simulators
(`ts-<worktree>-iphone-N`, plus an iPad for the `testIPad*` tests), keeps the iPhone clones booted for the next run,
and splits the UI tests across up to three clones, fewer when memory is short. The shards are balanced by each test's
measured time, averaged with the time stored before. Arguments after the tier go to xcodebuild, so `scripts/test.sh ui
-only-testing:CassiniUITests/NoteScreenTests` runs one class, still sharded. The header of `scripts/test.sh` lists its
environment variables. `scripts/test-remote.sh [tier]` runs the same tier on the Mac named by `CASSINI_MAC`, or here
when that is unset.

UI helper deadlines only bound hangs: menu taps require settled snapshots, Library navigation waits for loaded data
and UIKit presentation in an active scene before one tap, and text replacement waits for a cleared field and one edit.
A late destination or edit never triggers another input solely because a short deadline expired.

`CASSINI_RUNTIME=18 scripts/test.sh app` (or `ui`) runs on the newest installed iOS 18 simulator runtime instead of
the newest runtime; a version such as `18.2` or a runtime identifier also works. A run fails when no runtime matches,
or when the runtime cannot run the device types: below iOS 26 they default to iPhone 16 and iPad Pro 13-inch (M4).
That leg keeps its own clones (`ts-<worktree>-iphone18-N`), logs (`DerivedData/test-logs-ios18`) and UI timing table,
so it neither reuses nor disturbs the default leg, and it posts no commit status. `clean` deletes its clones too.

### The iOS 18 leg

`CASSINI_IOS18=smoke` adds an iOS 18 leg to `scripts/test.sh all`. It starts once the default runtime's tiers pass.
The worktree's clones are shut down first, and the same build then runs on the iOS 18 runtime: the hosted tests,
which load Whistle and ONNX Runtime for real, then the UI tests in `scripts/ios18-smoke-tests.txt` on one iPhone 16.
The list plans about five and a half minutes (332 s) by `scripts/ui-test-durations.tsv`. `CASSINI_IOS18=full` runs
every UI test and the `testIPad*` tests on an iPad Pro 13-inch (M4) instead. Once the leg is on by default, a branch
that changes views (`Cassini/Features` or `Cassini/Design` since it left origin/main) gets the full leg, and every
other branch the smoke run; `CASSINI_IOS18=smoke` or `full` overrides that choice.
`scripts/test.sh ios18` builds and runs only the leg. The leg is `CASSINI_RUNTIME=18 scripts/test.sh prebuilt`, which
tests the last build without building, so its clones, logs and timing table are those described above. The commit
status names what the leg ran and how, for example `passed in 24 min: iPhone 72/72, iPad 8/8; iOS 18.2 smoke: hosted
76/76 (6 skipped), iPhone 16/16`.

The iOS 18 test runtime is iOS 18.2 (22C150): Apple no longer offers 18.6 for download, and the app's floor is 18.0.
The leg is on by default (`ios18_default=smoke` in `scripts/test.sh`), so every Mac that runs `all` needs the iOS 18
runtime (install steps below). A Mac without it fails the run and its status before anything is built; the leg is never
skipped. With `ios18_default=off` an `all` run has no leg and its status says nothing about iOS 18. `CASSINI_IOS18=0` turns the leg off and posts no status, the same way `CASSINI_UI_IPAD=0` does.
`CASSINI_IOS18_RUNTIME=26` runs the whole leg on the installed iOS 26.0 runtime, to try it without iOS 18. There
every UI test is given the iOS 18 facts (below), so the iOS 18 side of each test runs, and the run posts no status.
In tests,
`DeviceUnderTest` (in `CassiniUITests`) reads which platform the device has, so the same test checks the iOS 18 screens
on 18 and the iOS 26 screens on 26 and 27. With `TEST_RUNNER_CASSINI_IOS18_FACTS=1`, every launch gets
`--ios18-platform` and those expectations follow, which runs the iOS 18 side on the current simulators.

Where a test needs a recognizer that runs and the system has no Apple speech, it launches the bundled Whistle
device of a 3 GB phone (`DeviceUnderTest.workingSpeech`, `--d78`); where it needs a speech model to download, the
Parakeet device (`DeviceUnderTest.downloadedSpeech`, `--parakeet`). With Apple speech both add nothing, so the iOS 26
and 27 runs launch with the same arguments as before. The statuses seed's paused job carries the recognizer of the
device it is seeded on, so Resume queues it on the Whistle device too. Every UI test now follows the platform: with the
iOS 18 facts, the smoke list passes on iOS 27, and the full leg (`CASSINI_IOS18=full`) passes on the iOS 26.0 runtime.
On the real iOS 18.2 runtime (10 November 2026, at bc7bb8e) the full leg passed: hosted 98/98 (7 skipped), iPhone
102/102, iPad 12/12. Earlier runs there had found the frame-budget regression (its cause, the turn model's per-word
regex rejoin, was fixed on main by #81, which measures the keystroke in main-thread CPU: 7.64 ms on 18.2 against
16 ms), a crash of every pinned-model download (on iOS 18 `Task(executorPreference: nil)` crashes; `PinnedModelInstaller`
now starts a plain `Task` when it has no executor), and seven UI failures, fixed on this branch: Name a speaker could
save a name one keystroke old (on every OS), the iPadOS 18 split view started without its sidebar, the running draft
did not follow its end, and the audit reported clipped text with no element on Settings and Saved voices. The leg
stays off by default for now.
`ScreenshotTests` skip unless `scripts/screenshots.sh` runs them.

To install the runtime, download the iOS 18.2 simulator runtime DMG (22C150) with the owner's Apple ID and keep it on
`/Volumes/DrMeyers2/sim-runtimes`. Do not `simctl runtime add` that DMG itself: simctl first stages a second 9 GB copy
of it on the internal disk and then copies the inner image as well, and on this Mac that second copy was refused twice
("the disk is almost full", with 27 and 30 GB free). Mount the DMG read-only from the external volume and add the image
inside it instead, which copies once:

```sh
hdiutil attach -nobrowse -readonly /Volumes/DrMeyers2/sim-runtimes/iOS_18.2_Simulator_Runtime.dmg
ls /Volumes/<mounted volume>/Restore/                  # one inner .dmg (092-09271-199.dmg for 22C150)
/usr/bin/lockf -k -t 3600 ~/.cassini-heavy.lock \
    xcrun simctl runtime add "/Volumes/<mounted volume>/Restore/<inner>.dmg"
hdiutil detach "/Volumes/<mounted volume>"
xcrun simctl list runtimes | grep 'iOS 18'           # iOS 18.2 (22C150) is listed
df -h /System/Volumes/Data                           # check what stays free on the internal disk
```

`simctl` copies the inner image, about 8.7 GB, into the system's store on the internal disk, and the first boot of the
runtime builds its dyld cache, about 3.5 GB more under `/Library/Developer/CoreSimulator/Caches`. The DMG stays
external as the backup. The leg then runs: `ios18_default=smoke` in `scripts/test.sh` is the one line that
turns it on.

On GitHub, `.github/workflows/ci.yml` runs `scripts/test.sh fast` and `scripts/test.sh build` on a hosted runner
with Xcode 27.0, for each push to main or a pull request that changes code. The simulator tiers run only locally: the
`drmeyers/test-all` status that `CASSINI_POST_STATUS=1 scripts/test.sh all` posts is what a merge looks for.

`scripts/screenshots.sh` takes the screenshots above. It runs `CassiniUITests/ScreenshotTests` on its own iPhone 17
and iPad Pro 13-inch (M5) clones, in light and dark, with the status bar pinned to 9:41. It then exports the named
attachments from the result bundle and saves them, scaled down, under `docs/screenshots/`. `--locale it` (or `fr`,
`es`, `pt-BR`, `pt-PT`) takes the same set in that language under `docs/screenshots/<locale>/`, which is not committed. `--device` and `--appearance` take a
subset. For a headless English gallery run, use
`scripts/screenshots.sh --locale en --appearance light --output /path/to/gallery/ios`.
The folder receives stable `light/01-library.png` through `light/09-saved-voices.png` names and
`ipad/light/01-split-landscape.png`, `ipad/light/02-split-portrait.png`. Custom output runs retain other files in the
chosen folder. Capture runs through `simctl` and XCTest; no Simulator window is needed.
For local before/after PR renders, fetch main and run (outside any enclosing heavy lock):

```sh
scripts/pr-shots.sh --base origin/main --out /path/to/new/pr-render
```

The base is the merge base of that ref and the head worktree (`--head PATH` defaults to this checkout).
Use a new output folder outside the worktree; commit changes and remove untracked files first. It renders all 22 existing English screenshots on each side, light and dark,
using the head's renderer/capture tests and one private simulator pair. Reading shots start paused,
so no pressed skip-button tint leaks into a capture. Each render takes `~/.scw-heavy.lock` itself
(or `CASSINI_HEAVY_LOCK`); the wrapper removes only its temporary worktree and uniquely named clones.
Output has `before/`, `after/`, per-side `shots.json`, logs and `render.json` with source SHAs and elapsed time.
`--output` disables lossy pngquant by default and records actual runtime/device, locale, seed, test and pixel size;
the 1200-pixel downscale remains. Existing normal README renders keep their previous compression behavior.

The canonical cassini-ux `pr-shots.py` is owned by the shared-tool seat. Until it merges, this command produces
renders/manifests only. Once available, `--diff-tool /path/to/pr-shots.py` (or a vendored `scripts/pr-shots.py`)
adds `pr-shots/` using its `diff` command when `--pr N` is supplied. `--render-only` skips that step. Activate that tool's pinned Python/Pillow environment first;
the wrapper uses `python3` from PATH.
This wrapper never accesses GitHub or publishes; the coordinator alone uploads images and replaces PR blocks.

`scripts/render-icon.swift` draws the app icon (`swift scripts/render-icon.swift` from the repository root).

UI absence assertions wait for a completed screen or app decision, then inspect the same accessibility state immediately.
Debug UI-test launches expose suggestion-completion, Settings-loaded and completed-scroll markers for this purpose.

UI-test launches (`--ui-testing`, Debug builds only) use a library and preferences of their own, a clock fixed at
Thursday 8 October 2026 09:41 UTC, en_US formatting, and fake transcription and speaker analysis. Named seeds fill the
library: `--seed library|search|reading|speakers|voices|trash|processing|recording|statuses|long`. `--parakeet` makes
the fake transcriber stand for Parakeet Ultra, so the model download screen and Settings show its sizes.
`--ios18-platform` builds the app over the iOS 18 platform facts (no Apple speech, no continued processing) on the
current runtime, so those flows are tested on the usual simulators. A normal
launch starts empty, and Release builds link no fakes.

UI-test word-tap checks read the last clamped seek target applied by the real audio adapter. Playback keeps advancing,
while the test-visible target stays fixed until another seek; the assertion has no playback-position time window.

The iOS UI-test harness also supports `--draft-growing`: its fake waits for
`cassini://ui-test/append-draft?count=K` before emitting K more synthetic sentences. Each permit advances the
injected transcription clock past the result-publication interval; tests wait for those actual new words.
Frozen fake reports advance virtual time too, so pace estimates do not depend on host scheduling. These Debug-only
controls are iOS harness extras; ordinary launches and production timing are unchanged.

### Native speech runtime

Every iOS build links sherpa-onnx from the same fork and commit as Android, codemyriad/sherpa-onnx `0c2ee3f` (D16 §1:
the NeMo frontend, Ultra's TDT selection by its plain URL, Nemotron-3 diarization), against ONNX Runtime 1.27.1, with
the C API and without TTS. Like Android it has speaker diarization on and applies Android's
`scripts/streaming-diarization.patch`, so the streaming Sortformer diarizer and the CAM++ speaker-embedding extractor
are in the build; `scripts/streaming-diarization-c-api.patch` (iOS only) puts the streaming calls into the C API,
because Android's patch adds them only to JNI. The build is published as the release
[`v1.13.7-cassini-mobile.1`](https://github.com/codemyriad/sherpa-onnx/releases/tag/v1.13.7-cassini-mobile.1)
(`sherpa-onnx-1.13.7-0c2ee3f-ios.2-no-tts.xcframework.zip`, and a mirror of csukuangfj's ONNX Runtime 1.27.1 static
xcframework), which `Package.swift` links as two binary targets by URL and checksum. Android's pure decode rules
(windows, quiet cuts, seam merge, word gate, speech feed, incremental 28 s windows) are ported with their tests to
CassiniNotebook/Transcription, and `ParakeetTranscriber` (CassiniInference) drives them over CassiniSherpa's
`ParakeetDecoder` and `SileroDetector`. The app uses Ultra when the device passes `SpeechCapability`, installed or not:
a job, or the model download screen's Download, fetches Ultra and its speech detector with consent through the installer
the speaker models share (`PinnedModels`). Apple's recognizer stays as the fallback, on iOS 26 or later, where
neither Whistle nor a verified Ultra can run (`AppleSpeechWindows`); iOS 18 has no Apple recognizer. Speakers run on
the same runtime: `CassiniSherpa` wraps Android's streaming Sortformer diarizer
(`SortformerStream`, with save and restore of its state) and CAM++ extractor (`VoiceprintExtractor`); the streaming
rules (`TurnHistory`, `SpeakerBudget`, `Diarization`, the voice-clip cache, `DraftNames` and draft stats) are in
CassiniNotebook, and the job (`WindowSpeakers`, `LiveMatching`, `DraftNamesStore`) in CassiniEngine. Without the native
runtime there is no speaker step. The speech detector hears the recording through WebRTC's 100 Hz high-pass
(`SpeechInputFilter`, decision D26.1), so a microphone's DC offset does not change what it finds; the recognizer and the
speakers get the samples raw ([differences](docs/differences.md#speech-recognition)).

```sh
scripts/build-sherpa-xcframework.sh   # pinned sources -> .tools/sherpa/SherpaOnnxC.xcframework and a reproducible zip
scripts/verify-native-runtime.sh      # the lock (scripts/native-dependencies.json) against Package.swift and the build
scripts/fetch-ci-models.py --dest .tools/models   # the pinned models from dist.gocassini.com, verified, in the app's
                                                  # layout (models/<id>/<source_sha256>/ with NOTICE.txt)
scripts/fetch-ci-models.py --check-live           # the live manifest still lists every pin (two small GETs)
scripts/sherpa-bench.sh               # simulator: Ultra decode vs Android's golden, memory and speed, and a real job
                                      # vs iOS's golden (CASSINI_PARAKEET_RECORD=1 records it)
scripts/speaker-smoke.sh              # simulator smoke: Sortformer streaming + save/restore and CAM++ on two FLEURS voices
```

**Models from the model host (D4, D53.1).** Every model Cassini installs itself comes from `dist.gocassini.com` and
from nowhere else: `ModelCatalog` compiles in the four pins (Parakeet Ultra INT8, Silero VAD, Nemotron 3 Diarization
INT8 with ONNX interface v2, CAM++), each as `(id, source_sha256)` with both SHA-256 values of every file. Before a
download, `NetworkModelFetcher` reads the live `manifest.json` and requires the pinned row and every artifact entry
(key, URL, sizes, both hashes, encoding) to agree with the pins (`DistManifest`); a missing or contradicted pin fails
with its own banner, "Model not available" (`DOWNLOAD_PIN_UNAVAILABLE`, no Retry; the Settings row keeps the generic
failed status, and the next install reads the manifest again). Each file is its own seekable
Zstandard object, resumed with Range and If-Range (the entity tag is the quoted compressed SHA-256; a `200` restarts
from zero whatever its tag, and a `206` without that tag or a `416` deletes the part) and checked before and after
decompression; the files and the host's `NOTICE.txt` are collected in
`CassiniModels/models/<id>/.<source_sha256>.staging/` and renamed into `CassiniModels/models/<id>/<source_sha256>/`.
On iOS, the model root, staging directories and resumed staging files use `completeUntilFirstUserAuthentication`
so verification can finish after auto-lock. A response with a validated length finishes at its pinned whole-file or
range boundary without waiting for connection teardown; size and SHA-256 checks still precede publication.
As an iOS URLSession recovery measure, a timeout or lost connection while reading the manifest or NOTICE gets one
retry with a separate session. It checks both metadata objects again and uses that session for the remaining model
requests. Artifact transfers keep their existing resume rules; cancellation, pin, HTTP and local storage failures
do not trigger this metadata retry.
Separately, an artifact request chain may retry once through an independent session if a GET times out or loses its
connection before response headers arrive. That retry preserves the current redirect target, hop budget and Range/If-Range
headers. Errors after headers do not trigger this retry; existing resume and partial-deletion rules still apply. Neither scope
retries cancellation, HTTP/status, pin/digest or local storage failures, and neither adds a delay or retries indefinitely.
About › Model notices shows that `NOTICE.txt` from an installed revision. Every request to the host, each redirect hop included, sends `User-Agent: CassiniTalk/<CFBundleShortVersionString> (iOS <version>; build <CFBundleVersion>)` (D54, `ModelUserAgent`), built once by the app and set by `URLSessionTransport`. Before the first load in each session every
installed file is hashed again (`ModelVerifier`, D16 §4); a file that differs retires the revision, the job fails
with "Model verification failed", and the next job downloads it again. Provenance names Ultra
`parakeet-ultra-0.6b-int8-v2@<source_sha256>` (D16 §5, D86). The default is the improved #4179 INT8 encoder
(`50c15b94…`): 465,446,146 compressed bytes and 671,608,018 installed bytes. The previous ID remains readable in
provenance and stays on disk until v2 is installed and verified; only then is its install removed. The model cache key
is derived from all pins and artifact hashes in `scripts/ci-models.json`, so v2 gets a distinct cache. These pins need the codemyriad sherpa-onnx fork at `0c2ee3f`
(D16 §1): an older runtime cannot load the v2 diarizer or the dist Ultra export.

`Package.swift` links the release's two xcframeworks into `CassiniSherpa`, the only module that imports `SherpaOnnxC`;
`CASSINI_SHERPA_LOCAL=1` links the ones `scripts/build-sherpa-xcframework.sh` writes to the gitignored `.tools/sherpa`
instead (the same bytes; `scripts/verify-native-runtime.sh` checks both against the lock). The binaries are iOS-only
(`.when(platforms: [.iOS])`), so `swift test` on macOS links no native code, but SwiftPM still downloads the two release
zips once when it resolves the package (about 41 MB, then cached in `.build` and SwiftPM's cache), and so does Xcode for
`scripts/test.sh` and `scripts/test-remote.sh`: the first run needs the network. Unlike Android's two ABIs, iOS builds
only the device (`ios-arm64`) and the Apple-silicon simulator (`ios-arm64-simulator`) slices, so every build is
arm64-only. `CassiniTests/SherpaBenchTests`, `CassiniTests/ParakeetJobTests`, `CassiniTests/SpeakerJobTests`,
`CassiniTests/SpeakerSmokeTests` and `CassiniTests/DCVectorTests` skip themselves unless the environment names their
models, as `scripts/sherpa-bench.sh` and `scripts/speaker-smoke.sh` do. `ParakeetJobTests` compares a real job's words
with `CassiniTests/Goldens/fleurs-it-short.ios.json`, recorded on the arm64 simulator with the dist export: iOS keeps
goldens of its own because ONNX Runtime's int8 kernels differ from those of Android's x86_64 emulator.
`scripts/fetch-speaker-fixture.py` mixes the speaker smoke test's two-speaker clip from public FLEURS audio (Android has
no public meeting recording) into the gitignored `.tools/fixtures`.

A new runtime is a new release asset: rebuild with `scripts/build-sherpa-xcframework.sh`, publish the zip, then put
its URL, version and SwiftPM checksum in `scripts/native-dependencies.json` and the same URL and checksum in
`Package.swift`, and run `scripts/verify-native-runtime.sh`.

[Validation](docs/validation.md) lists what each tier covers, the test counts and the device checklist.
[Architecture](docs/architecture.md) describes the modules, state ownership, startup, storage and the
transcription lifecycle.

## License

Copyright © 2026 Codemyriad and contributors.

Maintainer: Codemyriad <cassini@codemyriad.io>.

Cassini for iOS is free software under the [GPLv3](LICENSE). `Cassini/Resources/Licenses/ThirdPartyNotices.txt` lists
the licences of the dependencies and the models, including every library of the native runtime's lock
(`scripts/native-dependencies.json`, checked by `LicenseAssetsTests`); `ONNXRuntime-ThirdPartyNotices.txt` next to it is
ONNX Runtime 1.27.1's own notices for the libraries inside it. Both show under Settings → Source code and notices. The
portable format is specified in
[cassini-format](https://github.com/codemyriad/cassini-format).

### ZIP transfers (D96)

The Library import picker accepts multiple audio/Cassini files and ZIP archives. Edit selects notes for Export
Selected as ZIP; Export All as ZIP includes the whole live Library. Transfers show progress, support cancellation
and retain already imported notes. The [archive rules and iOS differences](docs/bulk-transfer.md) cover limits,
original-audio fallback, safe paths and cleanup. iOS uses its native picker/share sheet and AVFoundation audio
support; Android-only container support is not added.
