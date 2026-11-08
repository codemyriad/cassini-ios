# D75.2: pinned Needle on iOS 26

This is an offline compatibility spike, separate from the Apple Speech fix and from enabling Whistle in Cassini.
It does not access microphones, playback devices, accounts, device recordings or a physical device. It never changes
host mute/volume. Only a disposable simulator created by the runner is shut down/deleted.

Run the complete preparation/build/inference sequence under `/usr/bin/lockf -k ~/.cassini-heavy.lock` on drmeyers.
Do not overlap it with app gates, Android or Mac builds/model runs. The Apple Xcode26 SDK and iOS26.0 simulator runtime
must already be present. An iOS27 runtime is not a substitute. Keep at least 15 GB of disk space free.

1. `prepare.py --coord COORD --mac MAC_SOURCE --assets PINNED_MAC_ASSETS --output FIXTURES` validates the exact D5
   weights and arm64 Mac runtime, uses the reviewed Mac #167 FIR with contraction disabled, verifies the shared
   DC vector and VAD-input hashes, and freezes native Mac words on the reviewed DC segment PCM. It does not execute
   an iOS VAD; no VAD parity claim follows from an engine-only comparison.
2. `build.py --xcode26 XCODE_APP --artifacts PINNED_ENGINE_FOLDER --fixtures FIXTURES --output BUILD` checks the
   unchanged D5 archive hashes, links both device and simulator against their actual SDK26 stubs with target26.0,
   undefined-symbol errors and no weak imports, records every final imported symbol's SDK26 stub, dependencies,
   load commands and all linker warnings. The source archive's minos27 command is never rewritten. The resulting
   private framework is lazily loaded only after the telemetry guard. Simulator code is signed ad hoc; no upload,
   account operation, device signing or device installation occurs.
3. `run-simulator.py --build BUILD --fixtures FIXTURES` uses only runtime26.0 and an owned disposable iPad9 simulator.
   It requires exact text/word count/words and input hashes against the Mac, with at most80ms timing difference.
   The existing D11.5 clean-golden exception is not broadened to different DC input hashes. A failure remains a
   failure; no golden is regenerated from iOS output. JSON reports are copied out before deleting the owned device.

The framework/app retain model bytes through native lifetime and bound PCM/JSON; no Python runtime or model fetch
is included in the simulator app. Host preparation uses only pinned local assets. The generated manifest, weights,
PCM, executables, Xcode/runtime downloads and result logs belong under ignored build/cache paths, never in Git.

Passing proves the tested SDK26 link/import and simulator-native-recognition compatibility only. It does not prove
CPU compatibility, RSS/jetsam behavior or performance on an A12 3GB iPad8, the production iOS VAD pipeline, signing
for App Store distribution, or the full privacy sentinel/Included-model feature. D75.2 requires an approved lab-device
run before shipping a minos exception. The original iOS27 artifact metadata must remain documented even after a
successful target26 link; no default recognizer or production model support is changed by this spike.
