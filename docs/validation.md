# Validation

Validated on 11 October 2026 on an Apple Silicon Mac with Xcode 27.

- 15 existing Cassini format tests passed, with the published cassini-format conformance vectors required rather than skipped.
- 6 notebook tests passed: persistence, corruption isolation, safe paths, search, timing/subtitle export, and verified portable transcript import with overlapping speakers and unchanged source bytes.
- 4 iOS audio integration tests passed: CAF inspection, M4A conversion, source-preserving import, invalid audio rejection, and interrupted-work recovery.
- 5 iPhone 17 simulator UI tests passed: empty state/settings, capture error recovery, search/playback/rename/relaunch, model consent cancellation, and trash/restore.
- Release build for a generic physical iOS device succeeded with signing disabled.

UI tests use isolated, explicitly seeded silent audio. The host has no microphone input; the capture test validates the clear missing-input error and reusable controls. It does not establish physical microphone capture or transcription accuracy.

Screenshots are simulator UI examples. Real-device checks remain necessary for Apple model installation and recognition, long recordings, energy/thermal behavior, screen-locked capture, Bluetooth routes, and phone interruptions. Minimum supported iOS 26 also needs a device pass. No App Store upload or distribution signing was performed.
