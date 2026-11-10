# iOS 18

The app's deployment target is iOS 18.0 (`project.yml`). On iOS 26 and later it behaves as it did when the target was
iOS 26. Below iOS 26 two system features are missing, and the app does without them. Everything on this page about
iOS 18 is read from the code and its unit tests. **Nothing has run yet on an iOS 18 system: not on the iOS 18.6
simulator (the runtime is not installed on the build Mac yet), and not on a device.** Each statement below that
depends on that says "not yet verified on iOS 18.6".

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
those `sysctl` keys on an iOS 18 device is not yet verified: if the read fails, Whistle is refused on iOS 18 rather
than allowed to crash on first use. The `WhistleBundle` "CPU features" log line shows the answer on a device.

## Background on iOS 18

Without continued processing, work that leaves the screen gets only the finite background time iOS allows (about
30 s, not guaranteed). Not yet verified on iOS 18.6.

- **Transcription.** When the time ends, the job pauses with its checkpoint kept (at most 30 s of audio is redone),
  the queue is held as paused by the system, and while Cassini is hidden the notification "Transcription paused by
  iOS" is posted. Resume in the app continues from the checkpoint. On iOS 18 this happens to every transcription that
  is still running about 30 s after the person leaves the app.
- **Standalone model download** (Settings, the model download screen). When the time ends it stops and shows "iOS
  stopped the download. Try again to continue where it stopped."; the bytes already downloaded are kept and Try
  again resumes them.
- Recording and playback are unaffected: they keep running in the background through the `audio` background mode,
  as on iOS 26.

Android keeps both running in a foreground service, so this is a platform difference (decision 5 below).

## Whistle at iOS 18.0

The pinned Needle archives declare minos 27.0 and are used unchanged. D75.2 allowed linking them at target 26.0;
Silvio's decision of 2026-11-10 (D85, decision 1 below) extends that exception to 18.0. There is one framework for
every OS version, linked at 18.0 (decision 3). [Whistle/README.md](../Whistle/README.md) has the contract, what has
been shown with the 18.0-linked framework on the iOS 26.0 and 27.0 simulators, and the evidence still pending on the
iOS 18.6 simulator: the runtime export check, the 13 parity fixtures and the hosted Whistle tests. Until those pass,
nothing has shown that the framework loads or transcribes on iOS 18. No iOS 18 device is known (decision 8), so there is
also no device run, no memory measurement and no TestFlight acceptance on iOS 18.

## How it is tested today

- `swift test` covers both values of every platform fact and the CPU rule.
- App-hosted unit tests pass the iOS 18 facts directly (`CassiniTests/PlatformCompositionTests`): the engine choice
  per device class, the unavailable Apple candidate, Settings, and the background runner taking the finite time.
- The `--ios18-platform` launch argument (DEBUG `--ui-testing` launches only; the build is the same) makes the app
  use the iOS 18 facts on the current simulator runtime (iOS 27). UI tests launched with it check the engine choice
  and the Settings rows (`SettingsFlowTests`, `SpeechUnavailableTests`, `ParakeetSuggestionTests`); no UI test
  checks the finite background path. This runs iOS 27's system and UIKit with iOS 18's rules; it says nothing about
  iOS 18's own system chrome or APIs.
- `scripts/test.sh build` runs `scripts/check-embedded-minos.py`: no embedded binary or plist may need a newer iOS
  than the app.
- Not yet: any run on the iOS 18.6 simulator runtime, and the pre-iOS 26 system chrome (the back button's text,
  navigation bar material, scroll following), which only such a run can show.

## Decisions recorded

From the coordination file `REPLIES-IOS18.md` ("Decisions recorded", 2026-11-10) and the coordinator's D85, relayed
on Silvio's behalf. Decisions 1 and 2 are Silvio's. Decisions 3 to 8 are the iOS 18 agent's recommendations, applied
as the coordinator asked and **awaiting Silvio's review**; any of them can still change.

| # | Decision | Answer | Source |
|---|---|---|---|
| 1 | Link the iOS 27 Whistle binary at target 18.0 | **Yes**, on this evidence: the import check against the 18.6 runtime, the 13 parity fixtures and the app-hosted Whistle tests on the 18.6 simulator, plus the A12 measurement on iPadOS 26. This extends the D75.2 exception | Silvio |
| 2 | Install the iOS 18.6 simulator runtime | **Yes**, keeping at least 25 GB free on the build Mac's internal disk afterwards | Silvio |
| 3 | One Whistle binary or two | **One**, linked at 18.0, for all OS versions. The iOS 26 simulator parity is rerun on it; the next TestFlight build from main repeats the A12 acceptance | recommendation, awaiting Silvio's review |
| 4 | A10 iPad (7th generation) | Whistle is gated off by CPU feature (atomics and RCpc). That device records, plays and exports but does not transcribe | recommendation, awaiting Silvio's review |
| 5 | Background on iOS 18 | Accepted as described above: a transcription pauses about 30 s after leaving the app and needs Resume; the standalone download stops and needs Try again. No `BGProcessingTask`, no background `URLSession` | recommendation, awaiting Silvio's review |
| 6 | Merge gate | The iOS 18 test leg is folded into `drmeyers/test-all`: a smoke run on every `all`, the full iPhone run for PRs that touch views | recommendation, awaiting Silvio's review |
| 7 | iPad on iOS 18 in the test leg | Only in the full-run tier | recommendation, awaiting Silvio's review |
| 8 | Physical iOS 18 device | None assumed. Support ships on simulator evidence plus the A12 measurement on iPadOS 26, so there is no D75.2 lab-device run, no memory measurement and no TestFlight acceptance on iOS 18 | follows from decision 1; Silvio to confirm whether a device exists |

Decisions 6 and 7 describe a test leg that is not on this branch.
