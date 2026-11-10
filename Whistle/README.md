# Private bundled Whistle: D75.2 production increment

This app bundles the unchanged published Needle 3.3.0 device/simulator arm64 archives and the D5 Whistle weights,
with immutable Hugging Face revisions, lengths and SHA256 in `pins.json`. Build-time fetching is the only download;
missing or corrupt inputs fail the build. Cached corruption is never silently repaired. Models, generated binaries,
archives and cache contents stay out of Git. `scripts/bundle-whistle.py` makes a private signed framework and copies
the verified weights into the app; it is not linked for pre-main loading. x86_64 simulators have no pinned artifact
and omit the bundle rather than pretending to support it. The existing Parakeet runtime is retained independently.

## Documented source-archive minos exception

The original device and simulator objects declare **minos 27.0**. They are deliberately unmodified. The private
framework links with target **18.0**, the app's own deployment target: Silvio decided on 2026-11-10 (recorded in the
coordination file `REPLIES-IOS18.md`) to link the iOS 27 archive at 18.0, widening the coordinator's 2026-11-08
authorization for 26.0. All original newer-object warnings remain visible. No deployment-warning suppression or
Mach-O rewriting is used.

`pins.json` `deploymentTarget` is the one place the target is set. `scripts/bundle-whistle.py` reads it for the link
triple, the minos assertion, the framework's `MinimumOSVersion` and the manifest's `minimumOS`. In the app,
`WhistleCapability.minimumOperatingSystemMajor` is the OS floor, and `WhistleRuntime` accepts only the manifest
that floor implies. `WhistleRequirementsTests` ties both to the pin. `scripts/check-embedded-minos.py` has no
exception: the framework must not need a newer iOS than the app.

The unchanged spike at c65073cf07b493c4e0be4c3a898ecabacde13de8 used actual Apple Xcode26.0/17A324 SDK26 device and
simulator links, with undefined-symbol errors and no weak imports. Every runtime import was found in SDK26 stubs
(126 device/125 simulator). `sdk26-imports.json` records that exact closure. It is an SDK 26 audit, not an iOS 18
one, and keeps its name. Each production link, now at target 18.0 with the Xcode 27 toolchain, must import exactly
that set: an import outside it, or one of it missing, fails the build. A toolchain or pin change that alters the set
requires a fresh audit, not an edited list.

On actual simulator26.0/build23A343, all13 public/shared fixtures matched their frozen Mac counterparts exactly in
text, language, count and104 word strings, with maximum80ms word-time delta. Frozen manifest SHA256:
`8b64ff835753ddb97414a7fb48f050c375a13e7dd3ef410c33eae449d3b7e51d`.
The full original reports/logs are in coordination `evidence/ios/d75-2-2026-11-08/`. These are SDK/simulator
compatibility results, not physical A12/3GB, production-VAD, thermal or distribution-signing results. That run used
the spike's 26.0-linked probe framework; the iOS 18 evidence below says what was rerun with the 18.0-linked one.

### iOS 18: what is proven and what is pending

Linking for 18.0 changes only the framework's `LC_BUILD_VERSION` (minos 18.0 instead of 26.0), its `LC_UUID`, and
the plist and manifest minimums. Every section's bytes, the other load commands and the import set are unchanged
(compared on both slices). Because the runtime identity (`cassini-whistle-sections-v1`) hashes those two commands,
both slices have new `runtimeIdentity` values, on iOS 26 as on 18. The A12/3GB measurement on iPadOS 26 was made
with the 26.0-linked framework; the next TestFlight build from main repeats the A12 acceptance with this one.

Proven so far, with the 18.0-linked framework (decision 3 in `REPLIES-IOS18.md`: one framework for all OS versions):
- the link imports exactly the SDK 26 audit, and links only `libc++` and `libSystem`;
- every simulator import is exported by the installed iOS 26.0 and iOS 27.0 simulator runtimes
  (`scripts/check-whistle-runtime-exports.py`); on 26.0, five libsystem_kernel/pthread imports (`_getrusage`, `_mmap`,
  `_munmap`, `_pthread_create`, `_pthread_setspecific`) resolve through the host Mac's libraries instead, listed under
  `resolvedByHost` (the tool's `proves` field says `partial` there);
- the hosted Whistle tests (`WhistleRuntimeTests`, `WhistleRecordingAdapterTests`) load and run it on the iOS 27.0
  and iOS 26.0 simulators;
- the 13 fixtures above match the frozen Mac results exactly again (104 words, at most 80 ms) on the iOS 26.0
  simulator (23A343), run by the spike's unchanged driver around the simulator framework Cassini embeds;
- the CPU rule: the archive needs FEAT_LSE and FEAT_LRCPC; unit tests show that a CPU reporting either as missing or
  0 (the A10's values) is refused and the A12's values are accepted (`WhistleCapability.supports(cpu:)`). The app reads
  them from `hw.optional.arm.*` only below iOS 26 (`supports(cpu:operatingSystemMajor:)`): every iOS 26 device is an
  A12 or newer, so iOS 26 keeps Whistle whatever the read answers. The live read has only run in the simulator, with
  the host Mac's features; no A10 or iOS 18 device has run it.

**Pending the iOS 18.6 simulator runtime** (not installed on drmeyers yet). Until all three pass, nothing has shown
that the framework loads or transcribes on iOS 18:
- **Runtime export check.** Run `scripts/check-whistle-runtime-exports.py <iOS 18.6 RuntimeRoot>
  <Debug-iphonesimulator Cassini.app>/Frameworks/CassiniWhistleRuntime.framework/CassiniWhistleRuntime` and keep its
  JSON as `Whistle/runtime-exports-ios18.6-simulator.json`. *Placeholder: that file does not exist yet.* Imports the
  tool lists under `resolvedByHost` bind to the Mac's own libraries in the simulator, so they say nothing about
  iOS 18's: if the 18.6 runtime ships loose dylibs, its `proves` field will say `partial`, and the review of that
  file must name those symbols as not covered rather than read its `pass` as covering all of them.
- **Parity.** The 13 fixtures above on an iOS 18.6 simulator, with the 18.0-linked simulator framework. The harness
  that reran them on 26.0 is outside the repository, on drmeyers under
  `/Volumes/DrMeyers2/cassini-ios18-cache/ios18-e/evidence/parity-harness/` (`run-parity.py --runtime 18.6`):
  `build-probe.py` SHA-256 `c1d0de194bcf9fe23302cc997fca003373724e00a1e9a0507ffbef5c6332c785`, `run-parity.py`
  SHA-256 `f388ecd5e231a26630a512864e6e701f7eca4dfb66248a83a5c807caf0e8878b`. It compiles the spike's unchanged
  `scripts/whistle-ios26-spike/driver.mm` (SHA-256 `a1b827dfa6c6fc2bdd6b3d692cb3b4231dc616be4be588aeca427a4e64094afd`)
  from the `whistle-ios26-spike` worktree; check all three hashes before trusting a rerun.
- **Hosted tests.** `WhistleRuntimeTests` and `WhistleRecordingAdapterTests` on an iOS 18.6 simulator.

Even then, simulator evidence covers only the simulator archive and the simulator's libraries on the Mac's CPU.
Nothing yet speaks to the device slice on iOS 18. The import list was audited against SDK 26 stubs, and the A12 run
was on iPadOS 26 with the 26.0-linked framework. The pending 18.6 export check covers only the simulator's libraries
(and lists what the host Mac supplies apart). Device loadability on iOS 18 needs a physical iOS 18 device or TestFlight
run. There is no memory measurement on 18 either. That an app can read the `hw.optional.arm.FEAT_*` keys on a device
is also unverified: on iOS 18 a refused read turns Whistle off (it never lets an A10 through); on iOS 26 the read is
not consulted. The `WhistleBundle` "CPU features" log line shows the answer in the next TestFlight run on a device.

## Loading and capability selection

`CassiniWhistle.WhistleRuntime.shared` is the only process-global engine owner. It hashes the weights and
the framework’s signing-stable section identity before `dlopen`, sets and checks all three privacy flags before engine constructors, resolves
the narrow C API, and copies weights into explicitly owned storage retained for every native borrow, including dyld-retained C++ images. Raw-segment calls are serial,
bounded to240128 samples (15.008s: the desktop’s15s limit rounded to a512-sample frame) of finite16kHz mono PCM and1MiB of JSON, use automatic language detection and word timestamps, validate
finite/ordered/in-range words, and discard a result after cancellation. No microphone, playback, network client,
Python runtime or system-library search is involved. The app does not load the native framework at launch. Bundle integrity is verified once per bundle URL on a utility queue; startup awaits that shared result before queue readiness. Views and synchronous capability reads use cached state only.

## D78 starter model and verified upgrade

Whistle is the immediate bundled default on arm64 devices from iOS 18 with FEAT_LSE and FEAT_LRCPC (A12 and newer:
on iOS 18 the CPU must report both, so the A10 iPad 7th generation on iPadOS 18 is refused; every iOS 26 device has
them), with verified assets and the measured 3GB-class
memory floor (at least2GiB reported physical RAM,512MiB available before load,256MiB per window). The physical
A12/3GB gate on iPadOS 26 and the iOS 26 adapter/DC gates below back this rollout; the iOS 18 evidence is pending (see
above). The pending capability factory remains
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

## Validation and cache

`python3 scripts/test-bundle-whistle.py` covers missing/corrupt inputs, the import set and the pinned target;
`python3 scripts/test-check-whistle-runtime-exports.py` covers the runtime-export check on synthesized runtimes. Swift package tests
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
