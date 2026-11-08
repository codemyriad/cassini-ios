# Private bundled Whistle: D75.2 production increment

This app bundles the unchanged published Needle 3.3.0 device/simulator arm64 archives and the D5 Whistle weights,
with immutable Hugging Face revisions, lengths and SHA256 in `pins.json`. Build-time fetching is the only download;
missing or corrupt inputs fail the build. Cached corruption is never silently repaired. Models, generated binaries,
archives and cache contents stay out of Git. `scripts/bundle-whistle.py` makes a private signed framework and copies
the verified weights into the app; it is not linked for pre-main loading. x86_64 simulators have no pinned artifact
and omit the bundle rather than pretending to support it. The existing Parakeet runtime is retained independently.

## Documented source-archive minos exception

The original device and simulator objects declare **minos27.0**. They are deliberately unmodified. Following the
coordinator's 2026-11-08 authorization after the compatibility spike, the private framework links with target26.0;
all original newer-object warnings remain visible. No deployment-warning suppression or Mach-O rewriting is used.

The unchanged spike at c65073cf07b493c4e0be4c3a898ecabacde13de8 used actual Apple Xcode26.0/17A324 SDK26 device and
simulator links, with undefined-symbol errors and no weak imports. Every runtime import was found in SDK26 stubs
(126 device/125 simulator). `sdk26-imports.json` records that exact closure. Each production link rejects imports
outside it; a toolchain/pin change adding any import requires fresh SDK26 evidence, not an expanded guessed list.

On actual simulator26.0/build23A343, all13 public/shared fixtures matched their frozen Mac counterparts exactly in
text, language, count and104 word strings, with maximum80ms word-time delta. Frozen manifest SHA256:
`8b64ff835753ddb97414a7fb48f050c375a13e7dd3ef410c33eae449d3b7e51d`.
The full original reports/logs are in coordination `evidence/ios/d75-2-2026-11-08/`. These are SDK/simulator
compatibility results, not physical A12/3GB, production-VAD, thermal or distribution-signing results.

## Loading and capability selection

`CassiniWhistle.WhistleRuntime.shared` is the only process-global engine owner. It hashes the weights and
the framework’s signing-stable section identity before `dlopen`, sets and checks all three privacy flags before engine constructors, resolves
the narrow C API, and copies weights into explicitly owned storage retained for every native borrow, including dyld-retained C++ images. Raw-segment calls are serial,
bounded to240128 samples (15.008s: the desktop’s15s limit rounded to a512-sample frame) of finite16kHz mono PCM and1MiB of JSON, use automatic language detection and word timestamps, validate
finite/ordered/in-range words, and discard a result after cancellation. No microphone, playback, network client,
Python runtime or system-library search is involved. The app does not load the native framework at launch.

`WhistleCapability` separates artifact compatibility from accepted device/pipeline evidence. Pending acceptance is
false even when a bundle is present and hash-correct; no invented physical-RAM threshold claims support. The pure
`WhistleSelection` policy chooses an accepted Whistle where Apple is unavailable or the device is too small for
Parakeet, otherwise retaining eligible Parakeet/Apple candidates. An unaccepted bundle cannot make Apple eligible.

## Internal recording adapter and selection

The regular Release/App Store build remains gated and ignores the experimental preference. The explicit
`CassiniInternal` scheme archives configuration `Internal` with `CASSINI_INTERNAL_TESTFLIGHT`; its export must set
`testFlightInternalTestingOnly=true`. Internal Settings offers Whistle off by default, only while arm64/iOS26,
verified runtime/weights/VAD and conservative memory headroom permit the experiment. A12/3GB passes the ABI/OS/RAM
criteria (>=2GiB physical RAM, >=512MiB available before load); this is permission to measure, not a device-class
acceptance claim. Every segment rechecks >=256MiB headroom. No acceptance flag becomes true for this experiment.

A preference change takes effect on the next process launch. New jobs persist `recognizer`; resumed jobs keep it,
even after changing the default. Legacy jobs without this field stay with the legacy Parakeet/Apple candidate.
Admission and execution resolve the same persisted backend. Unknown identities, or Whistle jobs in a regular
Release build, fail closed. Start over explicitly discards the old checkpoint before adopting the new default.
Bundled Whistle needs no model-download consent; speaker download consent remains separate.

`WhistleTranscriber` reads files in bounded batches. Native16k input passes through;48k input uses the desktop’s
97-tap centred FIR with contraction off. Other rates/downmix use AVFoundation before that48k FIR (an iOS platform
difference, not an exact-resampler parity claim for those inputs). HPF100 runs continuously only on the VAD branch.
Silero6.2.1 is pinned at2327524 bytes/SHA1a153a22…; its CPU runtime is the app’s existing pinned ONNX Runtime1.27.1,
versus desktop1.23.2. Flags precede VAD environment/session creation and telemetry is disabled explicitly. The
existing statically linked ORT image is already present at app launch; this is not a new claim of pre-main network
isolation. Needle stays separately lazy-loaded after pin/privacy checks. iOS native execution remains in process.

The gate uses512-sample votes/hysteresis, pre-roll and desktop silence/duration cuts. Recognition receives raw FIR
samples, never the high-passed copy. Both full DC recordings passed all six exact desktop boundaries on an actual
26.0 simulator, and the English bundled recording passed the real adapter. The native raw-segment13-fixture frozen
reference remains unchanged. Resume deterministically rereads from zero to restore FIR/filter/recurrent VAD state;
finalized words are deduplicated at the checkpoint. Detected languages survive checkpoints and exports report actual
Whistle/Needle/model/pipeline identity rather than Apple Speech.

**Native lifetime:** the C API has no documented model-unload operation. dyld can retain an image with C++ TLS
(`__tlv_atexit`) after `dlclose`. Cleanup checks `RTLD_NOLOAD` and `needle_models`; it never frees weights still
borrowed by a resident model. That single owned model is reused on subsequent sessions. VAD/session allocations
are released normally. Retained ASR memory counts toward the device test and subsequent speaker-memory preflights;
releasing `NativeBudget` serializes execution but does not promise that dyld discarded the image. A repeated-session
regression exposed this and passes with ownership preserved. Do not infer physical suitability from simulator RSS.

Internal diagnostics record kernel peak physical footprint/RSS, observed low headroom, memory warnings, thermal
state, elapsed time, outcome and model residency. A whole-job observer includes the speaker step. Reports contain
no audio, words, note IDs or paths. `--internal-whistle-lab` selects a separate library/preferences/models/exports
root; an explicitly bundled lab-only English fixture exercises the real app without opening the user’s recordings.
`CASSINI_WHISTLE_LAB_FIXTURES=1` is a local diagnostic build input, never enabled for TestFlight export. Do not disable
jetsam or attach LLDB for memory acceptance. The authorized A12/3GB iPad (iPad11,6, iPadOS26.6.1) passed the physical measurement: cold whole-app words transcription peaked at95274464B physical footprint/170754048B RSS; ten maximum240128-sample windows with VAD resident peaked at91244000B footprint/175931392B RSS with1853422112B minimum available. Ten exact repeat results and model-ready cancellation passed; zero memory warnings, nominal thermal state. The separate lab sandbox used a public English fixture, Release optimization and default memory limit, without a debugger or jetsam override. Downloaded speaker models were absent. These measurements await review; acceptance flags and regular Release defaults remain unchanged.

## Distribution integrity

Distribution re-signing/stripping changes a complete Mach-O file hash. The manifest now pins
`cassini-whistle-sections-v1`: arm64 dylib code/data section bytes and metadata, plus platform/dependency/UUID/source
version commands. Unknown commands, malformed ranges and encrypted images fail closed. Mutable signing/linkedit
metadata is excluded from this additional pin; Apple’s normal loader verifies the complete code signature before
constructors. This section identity supplements code signing, never replaces it. No load commands are rewritten.
Actual build5 archive/export section identities match despite their different signed-file hashes; Swift/Python
parsers agree through actual bundled native tests. The original source-archive/weights pins are unchanged.

## Validation and cache

`python3 scripts/test-bundle-whistle.py` covers missing/corrupt inputs and unproven imports. Swift package tests
cover every eligibility gate, fallback selection, refusal before load for six missing/wrong flag cases, and invalid
native output. The hosted `WhistleRuntimeTests` is mandatory on arm64 and loads the actual app-bundled engine. The immutable public JFK WAV is hash-identical to the frozen spike input,
fetched only for Debug or explicit local lab builds and compared to the frozen Mac text/language/22 words and80ms timestamp bounds;
it is absent from normal Release and internal TestFlight exports. Neither waveform nor model weights are committed.

Builds default to ignored `.tools/whistle` for inputs. Set `CASSINI_WHISTLE_CACHE` to another cache root if needed.
On drmeyers all tools/build outputs/caches live on `/Volumes/DrMeyers2`, and the build runs under the shared heavy
lock. Never nest a lock around `scripts/test.sh`, which already takes it. No generated framework or model is committed.
