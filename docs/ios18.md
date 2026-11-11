# iOS 18

The app's deployment target is iOS 18.0 (`project.yml`). On iOS 26 and later it behaves as it did when the target was
iOS 26. Below iOS 26 two system features are missing, and the app does without them. Everything on this page about iOS
18 is read from the code and its unit tests, except what has run on iOS 18 (below): the full iOS 18 test leg on the
iOS 18.2 simulator, the iOS 18 test runtime since Apple no longer offers 18.6 (hosted 98/98, iPhone 102/102, iPad
12/12 on 10 November 2026), and two AWS Device Farm runs on 2026-11-10 (iPhone 11 on iOS 18.6.2, iPhone 15 on iOS
18.0), which ran only hosted Whistle and platform tests in a Debug build. Each statement below that none of these runs
covers says "not yet verified on iOS 18.2".

## What the system decides

The app reads the system once (`Cassini/App/LivePlatform.swift`) and passes the answers to the rules as values
(`PlatformFacts` in CassiniEngine, `WhistleCapability` in CassiniWhistle), so `swift test` covers both sides.

| | iOS 26 and later | iOS 18 to 25 |
|---|---|---|
| Apple speech (`SpeechAnalyzer`) | as before: the fallback candidate, checked per device and locale | none; its slot holds `UnavailableSpeechTranscriber`, which refuses every job |
| Speech language in Settings | on devices that use Apple speech | never shown |
| Whistle (bundled) | as before; the CPU features are read but not consulted | where the CPU reports FEAT_LSE and FEAT_LRCPC (`hw.optional.arm.*`) |
| Parakeet Ultra (downloaded) | as before: at least 5 GiB of physical memory | the same rule |
| Background time for the queue and the standalone model download | `BGContinuedProcessingTask` when started from the screen | `beginBackgroundTask` only; `BGTaskScheduler` is never called |

Whistle's other conditions are the same on both: an arm64 device, a verified bundle and at least 2 GiB of physical
memory.

## Which engine a device gets

New jobs use Whistle until Parakeet is installed and verified, then Parakeet (D78). Where Whistle cannot run, iOS 26
falls back to Apple speech; iOS 18 leads a Transcribe to the Parakeet download consent if the device can hold
Parakeet, as Android does, and otherwise refuses it before queueing with the same caption as a device without a
speech model (`SpeechModelPolicy.recognizer(preference:platform:)`).

The devices that stop at iOS 18 and cannot run iOS 26 (from Apple's support lists, not checked against the SDK):

| Device | Chip, memory | Engines on iOS 18 |
|---|---|---|
| iPhone XR | A12, 3 GB | Whistle only |
| iPhone XS, XS Max | A12, 4 GB | Whistle only |
| iPad (7th generation) | A10, 3 GB | none: the A10 lacks both CPU features and the memory for Parakeet. Recording, playback, search and export work; Transcribe is disabled |

A newer device kept on iOS 18 follows the same rules: Whistle on every one (A12 or later), Parakeet from 5 GiB.

The CPU rule is unit-tested with the A10's and the A12's values (`WhistleRequirementsTests`). That an app can read
those `sysctl` keys on an iOS 18 device is shown on an iPhone 11 (A13, iOS 18.6.2) and an iPhone 15 (A16, iOS 18.0),
which read both as 1 in AWS Device Farm runs on 2026-11-10. No A12 or A10 has run the read. If the read fails, Whistle
is refused on iOS 18 rather than allowed to crash on first use. The `WhistleBundle` "CPU features" log line shows the
answer on a device.

## Background on iOS 18

Without continued processing, work that leaves the screen gets only the finite background time iOS allows (about
30 s, not guaranteed). Seen on the iOS 18.2 simulator for a transcription (below, "How it is tested today"); not seen
on a device, and not checked for the standalone download.

- **Transcription.** When the time ends, the job pauses with its checkpoint kept (what a resume redoes is below),
  the queue is held as paused by the system, and while Cassini is hidden the notification "Transcription paused by
  iOS" is posted. On iOS 18 this happens to every transcription that is still running about 30 s after the person
  leaves the app. When Cassini comes back to the screen (or is launched again), the system's pause is resumed from the
  checkpoint without a tap, and the queue continues (`EnqueueRules.resumesOnActivation`); a pause or Stop of the
  person's own stays until Resume or Continue. Coming back first waits for the pause of a system stop that has not
  been written yet, then reads the hold and the paused jobs and clears the hold in one serial step, so a job just
  stopped is never read as still running and two quick activations resume it once; a system stop after that step keeps
  its hold. On iOS 26 nothing changes: there the system's pause can be the person's
  Stop in the system's progress, so it waits for Resume. Android has no such rule (its system pause comes only from the
  rare `onTimeout`, and waits for Resume); this is a proposal, decision 5 below.
- **Standalone model download** (Settings, the model download screen). When the time ends it stops and shows "iOS
  stopped the download. Try again to continue where it stopped."; the bytes already downloaded are kept and Try
  again resumes them.

What a resume redoes depends on the engine. Parakeet and Apple speech continue from the checkpoint, so at most 30 s
of audio is transcribed again. Whistle decodes the recording from its start again and drops the words before the
checkpoint (`TranscriptionJob`, `startMs`), so the words already written are kept but the time spent on them is paid
again on every resume. Whistle is the main engine on iOS 18, where these pauses are frequent: a long recording
finishes only if Cassini stays on the screen for a whole decode. This is not changed here.
- Recording and playback are unaffected: they keep running in the background through the `audio` background mode,
  as on iOS 26.

Android keeps both running in a foreground service, so this is a platform difference (decision 5 below).

## Whistle at iOS 18.0

The pinned Needle archives declare minos 27.0 and are used unchanged. D75.2 allowed linking them at target 26.0;
Silvio's decision of 2026-11-10 (D85, decision 1 below) extends that exception to 18.0. There is one framework for
every OS version, linked at 18.0 (decision 3). [Whistle/README.md](../Whistle/README.md) has the contract and what has
been shown with the 18.0-linked framework on the iOS 18.2, 26.0 and 27.0 simulators. On iOS 18.2 every simulator
import resolves (five only through the host Mac's libraries), the hosted Whistle tests pass and the 13 parity fixtures
match: the framework loads and transcribes on the iOS 18.2 simulator. On devices, two AWS Device Farm runs on
2026-11-10 (iPhone 11 on iOS 18.6.2, iPhone 15 on iOS 18.0) loaded it and transcribed the bundled English recording in
a Debug build (an A13 and an A16). There is still no A12 or A10 run, no memory measurement and no TestFlight
acceptance on iOS 18.

## Typing fast on iOS 18

On iOS 18.2 SwiftUI skips an `onChange(of:)` action when its value changes twice within one frame, and logs
"onChange(of: String) action tried to update multiple times per frame". A fast typist on a busy device puts two
keystrokes into one frame; when the skipped change is the last keystroke, the field's text holds it but the action
never sees it until the next edit. In Name a speaker that action is what gives the name to the model: on a heavily
loaded Mac the field showed "Anna Ricci" while the model kept "Anna Ric", and Save stored "Anna Ric"
(AcceptanceWalkTests, 10 November 2026). Measured with temporary logging on the iOS 18.2 simulator under load (not a
test): text fields' bindings received every keystroke in all 185 typings (125 of "Anna Ricci" into Name a speaker, 60
of "Thursday" into the Library search), the fault was logged in every run that captured the log, and once the model
kept "Anna Ricc" while the field and its binding held "Anna Ricci", still 20 s later. It is a skipped action, not a
late one, and not a lost binding write.

Below iOS 26, a text field whose edits change something else therefore also takes each edit from its binding's
setter (`Binding.handingEdits(to:)`, Cassini/Design/TextEdits.swift), which runs on every keystroke, and keeps its
`onChange(of:)` for changes made in code: Name a speaker (the name, the draft kept for a relaunch and the cut to 80
characters) and the Rename sheet (the draft and the cut to its limit; Save already read the text itself). Running an
action twice for one edit changes nothing (`NameSpeakerModelTests.aNameReportedTwiceIsTheSameAsOnce`). The other text
inputs read their binding directly when they act (the passage editor, the recording title, the in-note search, Add a
speaker), so a skipped action cannot reach them. The scene-restoration copies of the Library and in-note search
queries still follow `onChange(of:)`: after a skipped last keystroke, a relaunch restores the query without it.

The Library search wraps (`TextField(axis: .vertical)`), so Search on the keyboard arrives as a new line, which an
`onChange(of:)` turns into the end of the search. On iPadOS 18.2 that once did not happen: the field showed
"Thursday" and the new line, the search did not end and the keyboard stayed up (NoteReopenTests). It was put down to
the binding stopping at "Thur"; the measurement above found no lost binding write, so the skipped action is the likelier
cause. Below iOS 26 the field also reads every edit from its text view (`UITextView.textDidChangeNotification`),
follows it and ends editing on a line break (`LibrarySearchEdit`), which holds for either cause. iOS 26 keeps
`onChange(of:)` alone: neither failure was seen there.

## How it is tested today

- `swift test` covers both values of every platform fact and the CPU rule.
- App-hosted unit tests pass the iOS 18 facts directly (`CassiniTests/PlatformCompositionTests`): the engine choice
  per device class, the unavailable Apple candidate, Settings, and the background runner taking the finite time.
- The `--ios18-platform` launch argument (DEBUG `--ui-testing` launches only; the build is the same) makes the app
  use the iOS 18 facts on the current simulator runtime (iOS 27). UI tests launched with it check the engine choice
  and the Settings rows (`SettingsFlowTests`, `SpeechUnavailableTests`, `ParakeetSuggestionTests`). No UI test
  checks the finite background path: XCTest holds a "Developer testing (BackgroundUI)" assertion on the app under
  test, and in a UI test on the iOS 18.2 simulator Cassini stayed running in the background for 4 minutes with its
  task held and never expired, so a UI test cannot wait for the expiry. This runs iOS 27's system and UIKit with iOS 18's rules; it says nothing about
  iOS 18's own system chrome or APIs.
- `scripts/test.sh build` runs `scripts/check-embedded-minos.py`: no embedded binary or plist may need a newer iOS
  than the app.
- The iOS 18 leg (README) runs the same build on the iOS 18.2 simulator. On 10 November 2026 the full leg passed
  there: hosted 98/98, iPhone 102/102, iPad 12/12, so every UI test has run against iOS 18.2's own system chrome.
- The finite background path, without UI: `TranscriptionCoordinatorTests.Background` (`swift test`) follows a job
  from the expiry through a launch on the same files to a Resume that gives the run its checkpoint, with one job
  throughout; `AppGraphTests.testOnIOS18AJobPausedByIOSResumesFromItsCheckpointAfterARelaunch` does the same over the
  real job and files on the iOS 18 facts (the resumed run starts at the checkpoint and the note gets every word once);
  `PlatformCompositionTests` checks that the runner's expiry tells the work once and ends the finite token.
- By hand on the iOS 18.2 simulator, 10 November 2026 (iPhone 16; the processing seed with the bundled Whistle's fake,
  the Library on screen): the transcription's background task expired 32 s after it began, 27 s after Cassini left the
  screen; the job was stored paused by the system at 00:25 (its checkpoint); after a relaunch the note said "Paused
  at 00:25 of 48:13 · iOS ended the time Cassini had in the background", and Resume ended with the checkpoint's words,
  none transcribed again, and an empty queue. With a note open the time did not run out: the note's prepared player
  holds the audio session, and Cassini, which has the `audio` background mode, kept running in the background for over
  10 minutes with its job going on.
- The proposal that resumes the system's pause on coming back: `EnqueueRules.resumesOnActivation` (`swift test`,
  both platform facts and both holds), `TranscriptionCoordinatorTests.Activation` (only the system's pause, never the
  person's, not on the iOS 26 facts, after a kill, an activation before the system stop's pause is written, two
  activations at once or back to back, and a system stop during the activation) and `ActivationResumeTests` (hosted, from the checkpoint). By hand on the iOS 18.2 simulator the same day: coming back
  after the expiry the job ran again from 00:25 with no tap, and a launch after a kill while suspended resumed it and
  finished it with the checkpoint's words.
- Not yet: the finite background path on a device, the standalone download's stop, and any run on an A12 or A10 on
  iOS 18.

## Decisions recorded

From the coordination file `REPLIES-IOS18.md` ("Decisions recorded", 2026-11-10) and the coordinator's D85, relayed
on Silvio's behalf. Decisions 1 and 2 are Silvio's. Decisions 3 to 8 are the iOS 18 agent's recommendations, applied
as the coordinator asked and **awaiting Silvio's review**; any of them can still change.

| # | Decision | Answer | Source |
|---|---|---|---|
| 1 | Link the iOS 27 Whistle binary at target 18.0 | **Yes**, on this evidence: the import check against the 18.6 runtime, the 13 parity fixtures and the app-hosted Whistle tests on the 18.6 simulator, plus the A12 measurement on iPadOS 26. This extends the D75.2 exception. This evidence was gathered on 18.2, see decision 2 (below) | Silvio |
| 2 | Install the iOS 18.6 simulator runtime | **Yes**, keeping at least 25 GB free on the build Mac's internal disk afterwards. Apple no longer offers 18.6, so 18.2 was installed instead (below) | Silvio |
| 3 | One Whistle binary or two | **One**, linked at 18.0, for all OS versions. The iOS 26 simulator parity is rerun on it; the next TestFlight build from main repeats the A12 acceptance | recommendation, awaiting Silvio's review |
| 4 | A10 iPad (7th generation) | Whistle is gated off by CPU feature (atomics and RCpc). That device records, plays and exports but does not transcribe | recommendation, awaiting Silvio's review |
| 5 | Background on iOS 18 | Accepted as described above: a transcription pauses about 30 s after leaving the app and resumes from its checkpoint by itself when Cassini comes back to the screen (proposal: Android waits for Resume; the commit that adds it can be reverted alone); the standalone download stops and needs Try again. No `BGProcessingTask`, no background `URLSession` | recommendation, awaiting Silvio's review |
| 6 | Merge gate | The iOS 18 test leg is folded into `drmeyers/test-all`: a smoke run on every `all`, the full iPhone run for PRs that touch views | recommendation, awaiting Silvio's review |
| 7 | iPad on iOS 18 in the test leg | Only in the full-run tier | recommendation, awaiting Silvio's review |
| 8 | Physical iOS 18 device | None assumed. Support ships on simulator evidence plus the A12 measurement on iPadOS 26, so there is no D75.2 lab-device run, no memory measurement and no TestFlight acceptance on iOS 18 | follows from decision 1; Silvio to confirm whether a device exists |

Apple no longer offers the iOS 18.6 simulator runtime that decisions 1 and 2 name; the coordinator made iOS 18.2
(22C150) the iOS 18 test runtime, and decision 1's evidence was gathered there
([Whistle/README.md](../Whistle/README.md)).

Decisions 6 and 7 describe the iOS 18 leg (README); it is on by default (`ios18_default=smoke` in
`scripts/test.sh`). Decision 8 stands as recorded: the two AWS Device Farm runs on 2026-11-10 (iPhone 11 on
iOS 18.6.2, iPhone 15 on iOS 18.0) were not a D75.2 lab-device run, a memory measurement or a TestFlight acceptance.
