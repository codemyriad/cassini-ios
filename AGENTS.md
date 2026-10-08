# Working in this repository

- Sibling of `../cassini-android`; port behaviour from there and keep the same tests. Public format references live in `../cassini-format`, the desktop pipeline in `../gocassini`. Document differences from Android in the README.
- Linux cannot build Swift for Apple platforms here. Run `scripts/test-remote.sh` (host from `CASSINI_MAC`, default `ghyston`).
- `ghyston` is a 2014 Mac mini: macOS 12, Xcode 13.2.1, Swift 5.5, iOS 15.2 simulator. Keep code compatible with Swift 5.5 (no `if let x` shorthand, no regex literals, no `any`) until a newer Mac is available.
- Keep model weights, recordings, build outputs and generated Xcode projects out of commits.
