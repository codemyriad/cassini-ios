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
Python runtime or system-library search is involved. The app does not load the native framework at launch. Bundle integrity is verified once per bundle URL on a utility queue; startup awaits that shared result before queue readiness. Views and synchronous capability reads use cached state only.

## D78 starter model and verified upgrade

Whistle is the immediate bundled default on compatible arm64/iOS26 devices with verified assets and the measured
3GB-class memory floor (at least2GiB reported physical RAM,512MiB available before load,256MiB per window). The
physical A12/3GB gate and iOS26 adapter/DC gates below back this rollout. The pending capability factory remains
unavailable; the D78 bundled factory is separate from the earlier explicit internal experiment.

`SpeechModelPolicy` uses Whistle until Parakeet is installed and hash-verified, then defaults new jobs to Parakeet
when the native runtime and memory preflight permit it. File existence/size alone never promotes a model. An
asynchronous utility-queue verifier keeps Whistle usable while checking installed weights. The installer's verified
publication is visible immediately to new selection, without relaunching. An explicit Whistle choice remains valid.

Settings and the first completed Whistle result show the coordinator's calm Parakeet suggestion only on capable
devices, with the pinned compressed speech download size and sufficient install disk space. The result suggestion
is presented once; dismissal is persisted across both placements. The download action opens the existing consent
and progress flow with speech alone, so unrelated speaker downloads cannot change the advertised size. The
coordinator's once-only confirmation follows verified promotion. A12/3GB never sees a Parakeet suggestion.

New jobs freeze their backend before asynchronous consent checks, so an install or preference change during
admission affects the next request. Queued/paused jobs and checkpoints keep their concrete recognizer; legacy jobs
keep the pre-Whistle device backend. Consent sheets resolve the pinned job backend, saved language and install size, independently of the current Settings choice. Trash metadata preserves the identity; queue rebuild recovers it from known checkpoint model families. Unknown or unregistered identities fail closed. Bundled speech needs no
network consent; speaker downloads keep their independent consent. Internal builds retain the isolated lab and
memory reports; lab fixtures are never included in TestFlight exports.

## Distribution integrity

Runtime input pinning happens before Apple distribution: the build verifies the source archives, import closure
and weights/VAD hashes, signs the private framework, and records its clear code/data fingerprint as
`runtimeIdentity` / `cassini-whistle-sections-v1`. The strict Swift/Python fingerprint utility remains suitable
for clear build/export artifacts and rejects encrypted input. It is not an installed-runtime gate.

Actual TestFlight8 on the A12/3GB iPad failed at `runtimeIdentityParse`, `encryptedRuntime`, before loading native
code. The source/export pins passed, but Apple had encrypted its distributed copy. The old runtime check therefore
disabled Whistle and selected unavailable Apple Speech. This was a packaging-verification bug, not a RAM refusal.

The app now verifies the complete weights/VAD hashes and provenance metadata, and requires the regular runtime
file at its fixed path inside the running app's bundle. Another bundle and symlinks escaping that path are refused.
It then sets the privacy environment before `dlopen`; iOS authenticates the signed executable code when loading it.
Apple's encryption is opaque to Cassini. There is no receipt/DEBUG bypass, code decryption, load-command rewriting
or warning suppression. The minos27 exception and all source-archive/model pins remain unchanged.

This separates pre-Apple input provenance from installed executable authentication. Apple documents
[TestFlight/App Store re-signing and custom tamper-check limitations](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)
and [iOS code-signature validation for embedded frameworks](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web).
The startup gate verifies assets/location; the native loader authenticates code at first use. A missing runtime,
bad model hash or load/signature failure stays unavailable. No arbitrary or system runtime is searched.

`io.codemyriad.cassini` / `WhistleBundle` logs startup success or the first failed asset/location stage, the selected
recognizer and physical memory, and native load errors/model readiness. No recording content enters these logs.
Distribution acceptance requires a TestFlight-installed build (Beta signer, `get-task-allow=false`) to transcribe
the controlled English sample; an archive/export or sideloaded success is not that proof.

## Pausing and resuming a recording

Whistle saves finalized words with the exact source frame and its FIR, high-pass, Silero and speech gate state.
The checkpoint includes bounded raw overlap for an open segment and the gate's pre-roll. Resume seeks to the
saved frame with codec context, then restores that state before running the next block. The job appends the
new segments to its saved prefix, so timestamps stay on the recording clock. A paused checkpoint from before
this format is rebuilt once. A checkpoint with all words complete still goes straight to the speaker step.

The reader uses one-second source blocks. Codec priming rereads 100 ms before each block at standard rates
(and at most one second at unusual integer rates). Rate conversion uses the same bounded context on both
sides of a block, with the 48-to-16 kHz FIR kept continuous. A normal pause saves the latest complete batch.
At most one second of uncommitted source, plus the priming overlap, is reread. If interruption discards a
Needle result in flight, a retry can redo at most one open segment (15.008 s) plus one second of new audio.
Periodic checkpoints are saved every five seconds of processed audio, rounded up to the next block, so abrupt
process loss can redo less than six seconds of source work plus the priming overlap, or less than 22 seconds
of audio submitted to Needle. These are audio bounds, independent of device decode speed.

## Validation and cache

`python3 scripts/test-bundle-whistle.py` covers missing/corrupt inputs and unproven imports. Swift package tests
cover every eligibility gate, fallback selection, refusal before load for six missing/wrong flag cases, and invalid
native output. The hosted `WhistleRuntimeTests` is mandatory on arm64 and loads the actual app-bundled engine. The immutable public JFK WAV is hash-identical to the frozen spike input,
fetched only for Debug or explicit local lab builds and compared to the frozen Mac text/language/22 words and80ms timestamp bounds;
it is absent from normal Release and internal TestFlight exports. Neither waveform nor model weights are committed.

Builds default to ignored `.tools/whistle` for inputs. Set `CASSINI_WHISTLE_CACHE` to another cache root if needed.
On drmeyers all tools/build outputs/caches live on `/Volumes/DrMeyers2`, and the build runs under the shared heavy
lock. Never nest a lock around `scripts/test.sh`, which already takes it. No generated framework or model is committed.

## PR45 review regression coverage

The review fixes exercise needs-consent and paused legacy/Apple/Parakeet jobs while Whistle is selected, including
the real download sheet and consent-to-start transition. Event-driven tests cover queued Whistle trash/restore,
corrupt queue reconstruction, checkpoint/resume and mixed-language `mul` provenance. Shared language writer vectors
include Whistle. Bundle-cache tests hold the utility worker on an event, proving concurrent callers share one check
and synchronous cached reads perform no hashing. Live low-headroom admission recovers without a relaunch and is
checked again before opening audio. Hardware failure disables both Transcribe and Transcribe again; unsupported
locale keeps the language-refusal path. D78 Settings and first-result suggestion tests use the coordinator strings.
