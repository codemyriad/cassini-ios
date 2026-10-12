# Validation

Validated on 12 October 2026 on an Apple Silicon Mac with Xcode 27 and an iPhone 17 simulator running iOS 27.

## Automated checks

- 15 original Cassini format tests pass, with the published cassini-format conformance vectors required rather than skipped.
- 16 notebook tests pass, covering migration from version-one notes; stable speaker identities; passage attribution; isolated speech accounting; consistent renames; reversible merges and edited versions; one-to-one voice matching, model separation, exclusions, and ambiguous matches; removal of voice evidence and forgetting everyone; privacy of exports; calendar-day expiry across DST; persistence, safe paths, search, and subtitles.
- 2 codec tests pass: real stereo PCM → mono Opus → PCM conversion preserves duration and signal energy, and malformed Opus fails without deleting its source.
- 1 opt-in real-model test passes on the AMI ES2004a meeting (17 minutes 29 seconds), detecting four speakers and producing 256-dimensional embeddings. A second run succeeds with downloads disabled. A short Italian FLEURS recording also passed this test. Model weights and recordings are not committed.
- 7 iOS integration tests pass, including portable export → import → playback with unchanged original bytes, and saved-voice naming/persistence/forgetting plus trash expiry and suppression of stale in-flight voiceprints after Forget all. Voice matching integration checks default suggestions, opt-in automatic naming, absence of automatic enrollment, and exclusion of trashed evidence.
- 7 UI tests pass, including renaming a speaker and reopening the app, and cancelling then confirming Empty trash.

The model test demonstrates real inference and offline cache reuse. It is not a diarization-error-rate benchmark, a saved-voice false-match calibration, or an iPhone performance result. The two-minute interval initially tested from the same meeting yielded one speaker; the complete meeting yielded four. No inference accuracy is claimed from simulator screenshots.

The unsigned Release build for a generic physical iOS device also succeeds.

## Reproduce

```sh
# Format and app-model checks; model inference is skipped unless explicitly enabled.
CASSINI_CONFORMANCE=/path/to/cassini-format/spec/conformance \
CASSINI_CONFORMANCE_REQUIRED=1 swift test

# Real model check: downloads speaker models locally on the first run.
CASSINI_SPEAKER_AUDIO=/path/to/meeting.wav CASSINI_MIN_SPEAKERS=2 \
swift test --filter CassiniInferenceTests

xcodegen generate
xcodebuild -project Cassini.xcodeproj -scheme Cassini \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -collect-test-diagnostics never -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project Cassini.xcodeproj -scheme Cassini -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The AMI recording used for the optional check came from the [FluidInference AMI mirror](https://huggingface.co/datasets/FluidInference/ami-corpus-mirror/blob/main/sdm/ES2004a.Mix-Headset.wav). The model pipeline is pinned through [FluidAudio](https://github.com/FluidInference/FluidAudio/tree/e560c6445ffdc42e60c7b282d162aae271f18e2a). Voice evidence additionally records a fingerprint of the downloaded embedding-related model files, preventing matching across changed weights.

## Device work remaining

UI tests use isolated, explicitly seeded silent audio. This Mac has no microphone input, so the capture test verifies the missing-input error and recovery. Real-device checks remain necessary for microphone capture, Apple recognition/model installation, speaker accuracy, memory/thermal behavior, screen-locked capture, Bluetooth routes, and phone interruptions. Minimum supported iOS 26 needs a device pass. Automatic voice naming is optional and off by default pending representative-device calibration. No App Store upload or distribution signing was performed.

## Recording device checklist

Run on a physical iPhone with Live Activities enabled:

- Record, lock the phone: the Lock Screen shows the recording with its running time. Pause from the Lock Screen: the
  time stops and the button becomes Resume; Resume, then Finish from the Lock Screen: the note opens in Cassini with
  the audio saved.
- The Dynamic Island shows the recording (iPhone with a Dynamic Island) and a tap returns to the Recording screen.
- Receive a phone call while recording: the recording pauses with "Paused — another app is using audio" and stays
  paused after the call until Resume.
- Unplug wired headphones while recording through their microphone: the recording pauses with "Paused — audio input
  disconnected".
- Force-quit Cassini from the app switcher while recording, then relaunch: the recording is listed with a playable
  duration and the "recording recovered" notice shows.
- Fill the storage to about 15 minutes of recording above the floor: the warning shows, then the recording stops and
  saves at the floor without transcribing.
