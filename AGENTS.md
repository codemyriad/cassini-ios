# Working in this repository

- Sibling of `../cassini-android` (branch `rebuild`); port behaviour from there and keep the same tests. Public format references live in `../cassini-format`, the desktop pipeline in `../gocassini`. Document differences from Android in the README. Where iOS and Android disagree, Android's behaviour wins unless the difference is an iOS-only extra or a platform constraint.
- Toolchain: Swift 6.2+ tools, Swift 6 language mode, iOS 26 deployment target, Xcode 26 or newer (developed with Xcode 27). Build and test locally on macOS; `scripts/test-remote.sh` runs the same steps on another Mac named by `CASSINI_MAC`.
- Generate the Xcode project with `xcodegen generate`; never commit `Cassini.xcodeproj`.
- Keep pure rules (anything Android unit-tests) in Swift packages so `swift test` covers them; the app target holds composition, adapters and views only.
- Keep model weights, recordings, build outputs and generated Xcode projects out of commits.
