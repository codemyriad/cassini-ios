# Working in this repository

- Sibling of `../cassini-android`; port behaviour from there and keep the same tests. Public format references live in `../cassini-format`, the desktop pipeline in `../gocassini`. Document differences from Android in the README.
- Linux cannot build Swift for Apple platforms here. Run `scripts/test-remote.sh` (host from `CASSINI_MAC`, default `ghyston`).
- `ghyston` is a 2014 Mac mini: macOS 12, Xcode 13.2.1, Swift 5.5. It runs `swift test` and compiles the app, but cannot run the iOS Simulator reliably (8 GB RAM). A newer Mac is being procured; until then keep code compatible with Swift 5.5 (no `if let x` shorthand, no regex literals, no `any`).
- `scripts/simulator-remote.sh` builds with XcodeGen (`~/.local/xcodegen` on the Mac), installs into a Simulator with a document imported via `CASSINI_IMPORT`, and copies back a screenshot.
- Keep model weights, recordings, build outputs and generated Xcode projects out of commits.
