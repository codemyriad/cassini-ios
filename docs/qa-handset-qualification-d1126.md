# Physical Handset Qualification — iOS (`D-1126`, `D-1117`)

Empirical physical-handset qualification of `transcribeWhileRecording` vs. `afterStop` / `recordOnly` on real iPhones via AWS Device Farm (D89) for **Parakeet Ultra (+ streaming Sortformer + CAM++ saved voices)** and **Whistle**, prior to enabling recording-time precomputation on any iOS device profile.

- **Code baseline:** `bd600826` (`main`, after `D-1123` PR #179) + `CassiniTests/HandsetQualificationTests.swift` and `scripts/devicefarm-qualify.py`.
- **Shared contracts:** `cassini-ux/contract/HEAD-START-TRANSCRIPTION.md` (`D109`), `cassini-ux/decisions/DECISIONS-UX.md` (`D89`).
- **Shipped default:** remains `afterStop` (no UI or default-mode change in this PR).

---

## 1. Qualified Physical Handsets & Device Farm Runs

| Handset | Identifier | SoC / RAM | OS | Run Name | Result | Scope |
| --- | --- | --- | --- | --- | --- | --- |
| **Apple iPhone 11** | `iPhone12,1` | A13 Bionic / 4 GB (3,854 MiB) | iOS 18.6.2 (22G100) | `d1126-iphone11-5min-v2` | Equivalence & pressure PASS (`reports.json` captured; `.opus` raw-serial check fixed in v3) | 5-min paired Parakeet (+Sortformer +CAM++ 3 voices) & Whistle + pressure injection |
| **Apple iPhone 11** | `iPhone12,1` | A13 Bionic / 4 GB (3,854 MiB) | iOS 18.6.2 (22G100) | `d1126-iphone11-30min-parakeet` | **PASSED** (3/3, 32.65 metered min) | 30-min continuous real-time Parakeet + Sortformer precompute + Stop-to-transcript |
| **Apple iPhone 14 Pro** | `iPhone15,2` | A16 Bionic / 6 GB (5,663 MiB) | iOS 27.0 (24A437) | `d1126-iphone14pro-5min-v3` | **PASSED** (5/5, 5.77 metered min) | CAF prefix lifecycle + interruptions + 5-min paired Parakeet & Whistle (incl. decoded `.opus` SHA-256) + pressure injection |
| **Apple iPhone 14 Pro** | `iPhone15,2` | A16 Bionic / 6 GB (5,663 MiB) | iOS 27.0 (24A437) | `d1126-iphone14pro-30min-whistle` | **PASSED** (3/3, 31.46 metered min) | 30-min continuous real-time Whistle precompute + Stop-to-transcript |

---

## 2. Aggregate Hardware Qualification Table

### 2.1 Paired 5-minute (300 s) Multi-Speaker Speech Equivalence & Latency

Audio: 300 s 48 kHz mono PCM16LE 3-speaker real speech (bundled `WhistleTests/jfk.wav` at 1.00×, 0.86×, 1.16× pitch/rate profiles with 0.6 s silence gaps). Saved-voice store populated with **3 real CAM++-enrolled voices** (`Alice`, `Bruno`, `Carla`).

| Handset (OS) | Engine | Mode | Stop-to-Published (s) | Speedup | Post-Stop Units | Words / Speakers / Matched Voices | Peak Footprint (MiB) | Min Free RAM (MiB) | Memory Warnings | Peak Thermal | CPU Time (s) | Equivalence |
| --- | --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- | ---: | --- |
| **iPhone 11** (iOS 18.6.2, 4 GB) | `recordOnly` | control | 0.03 | — | 0 | 0 / 0 / — | 113.8 | 2,039.8 | 0 | `nominal` | 0.01 | N/A |
| **iPhone 11** (iOS 18.6.2, 4 GB) | **Parakeet + Sortformer + CAM++** | `afterStop` | **75.10** | 1.00× | 5 windows | 571 / 3 / `Alice, Carla` | 1,299.8 | 798.2 | 0 | `nominal` | 126.76 | baseline |
| **iPhone 11** (iOS 18.6.2, 4 GB) | **Parakeet + Sortformer + CAM++** | `transcribeWhileRecording` | **31.53** | **2.38×** | **2 windows** | 571 / 3 / `Alice, Carla` | 1,299.8 | 855.9 (pre) / 1,180.7 (post) | 0 | `nominal` | 100.50 + 40.63 (+11.3%) | **PASS** |
| **iPhone 11** (iOS 18.6.2, 4 GB) | **Whistle** | `afterStop` | **35.39** | 1.00× | 86 segments | 576 / — / — | 1,299.8* | 1,796.6 | 0 | `nominal` | 52.96 | baseline |
| **iPhone 11** (iOS 18.6.2, 4 GB) | **Whistle** | `transcribeWhileRecording` | **17.81** | **1.99×** | **5 segments** | 576 / — / — | 1,299.8* | 1,754.3 (pre) / 1,798.7 (post) | 0 | `nominal` | 39.60 + 18.74 (+10.2%) | **PASS** |
| **iPhone 14 Pro** (iOS 27.0, 6 GB) | `recordOnly` | control | 0.01 | — | 0 | 0 / 0 / — | 510.8 | 2,904.5 | 0 | `nominal` | 0.01 | N/A |
| **iPhone 14 Pro** (iOS 27.0, 6 GB) | **Parakeet + Sortformer + CAM++** | `afterStop` | **36.60** | 1.00× | 4 windows | 571 / 3 / `Alice, Carla` | 1,413.3 | 1,658.7 | 0 | `nominal` | 62.35 | baseline |
| **iPhone 14 Pro** (iOS 27.0, 6 GB) | **Parakeet + Sortformer + CAM++** | `transcribeWhileRecording` | **19.03** | **1.92×** | **2 windows** | 571 / 3 / `Alice, Carla` | 1,413.3 | 1,817.9 (pre) / 2,370.2 (post) | 0 | `nominal` | 62.66 + 24.77 (+40.2%) | **PASS** |
| **iPhone 14 Pro** (iOS 27.0, 6 GB) | **Whistle** | `afterStop` | **20.05** | 1.00× | 86 segments | 576 / — / — | 1,413.3* | 2,935.9 | 0 | `nominal` | 29.73 | baseline |
| **iPhone 14 Pro** (iOS 27.0, 6 GB) | **Whistle** | `transcribeWhileRecording` | **11.26** | **1.78×** | **5 segments** | 576 / — / — | 1,413.3* | 2,890.9 (pre) / 2,913.9 (post) | 0 | `nominal` | 20.32 + 11.82 (+8.1%) | **PASS** |

*\*`ledger_phys_footprint_peak` is a process-lifetime kernel high-water mark, so Whistle's process peak in the same `test02` process reflects Parakeet's earlier peak; see Section 2.2 for standalone Whistle peak (`257.0 MiB` recording / `415.8 MiB` post-Stop).*

### 2.2 30-minute (1,800 s) Continuous Real-Time Recording Qualification

Real-time paced 48 kHz `.caf` growth (`2 s` written and `fsync`'d every `2 s` for `1,800 s`) with live `CAFPrefixPrecomputer` under `transcribeWhileRecording`, followed by CAF finalization and immediate `TranscriptionJob` tail finalization.

| Handset (OS) | Engine | Checkpoints Saved | Stop-to-Published (s) | Words Published | Peak Footprint (MiB) | Min Free RAM (MiB) | Memory Warnings | Thermal Trajectory (61 × 30 s) | Recording CPU (s) | Post-Stop CPU (s) | Battery (USB-powered) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- |
| **iPhone 11** (iOS 18.6.2, 4 GB) | **Parakeet + Sortformer** | 68 | **12.34** | 3,392 | 1,587.6 | **511.1** | 0 | 61/61 `nominal` | 962.9 (~0.53 core avg) | 18.6 | 100% → 95% (`charging`) |
| **iPhone 14 Pro** (iOS 27.0, 6 GB) | **Whistle** | 1,797 | **0.40** | 3,426 | 257.0 (rec) / 415.8 (post) | **2,811.7** | 0 | 3× `nominal` → 58× `fair` | 199.5 (~0.11 core avg) | 0.68 | 100% → 95% (`charging`) |

---

## 3. Equivalence, Pressure Injection & Interruption Matrix

| Check | iPhone 11 (iOS 18.6.2) | iPhone 14 Pro (iOS 27.0) | Details |
| --- | --- | --- | --- |
| Live `.caf` prefix SHA-256 (`LiveCAFReader`) vs. finalized `.caf` | **PASS** | **PASS** | Bit-identical prefix digest across unfinalized (`data` size `-1`) and finalized CAF headers |
| Published `.opus` decoded PCM payload equivalence (`OpusAudio.encode` → `decode`) | **PASS** (after v3 fix) | **PASS** | Note: Ogg Opus container headers embed a random `serialno` per encode; decoded PCM payload digest is bit-identical |
| Parakeet words, word timings (`startMs`/`endMs`), Sortformer turns, CAM++ matches (`>= 3` voices) | **PASS** | **PASS** | Exact 571/571 words, 3 speakers, identical `["Alice", "Carla"]` voice matches |
| Whistle words & word timings (`startMs`/`endMs`) | **PASS** | **PASS** | Exact 576/576 words; post-Stop decoded segments dropped 86 → 5 |
| Injected thermal `.serious` + low-memory (`10 MiB`) + backgrounding yield & tail recovery | **PASS** | **PASS** | Paused within 1 window/segment; post-Stop `TranscriptionJob` produced identical final output for both engines |
| Pause → Resume, simulated call interruption (`AVAudioSession.interruptionNotification`), simulated BT route loss (`oldDeviceUnavailable`) | **PASS** (`testQualificationHarnessAndTelemetryContract`) | **PASS** (`test01RealCAFLiveReaderAndInterruptionLifecycle`) | `AVCaptureAdapter` paused cleanly, emitted `.interrupted` / `.routeLost`, resumed cleanly with 0 errors |

---

## 4. Device-Capability & Thermal Threshold Recommendations (for Silvio's Sign-Off)

1. **Memory thresholds (`ParakeetMemory.beforeLoadBytes = 1450 MiB`, `beforeWindowBytes = 400 MiB`) — keep unchanged.**
   - Over 30 continuous minutes of Parakeet + Sortformer on a 4 GB **iPhone 11**, `minAvailableMemoryMiB` stayed at `511.1 MiB` (`+111 MiB` headroom above `beforeWindowBytes`), with `0` memory warnings and `0` jetsam kills.
2. **Thermal yield threshold (`ProcessInfo.ThermalState >= .serious`) — keep unchanged.**
   - Neither handset reached `.serious` during 30 minutes of continuous precomputation (`nominal` throughout on iPhone 11; steady `fair` on iPhone 14 Pro). Injected `.serious` yielded cleanly within 1 window/segment.
3. **Default mode & energy trade-off — keep `afterStop` default until unplugged battery pass + user mode setting.**
   - Continuous 30-min Parakeet + Sortformer consumed `962.9 s` CPU (~0.53 core avg) on A13 and dropped battery `100% → 95%` even while USB-connected. Whistle was ~5× lighter (`199.5 s` CPU, ~0.11 core avg on A16, `257 MiB` peak footprint, `0.40 s` Stop-to-transcript).
   - Recommendation: expose the planned **Battery saving** (`recordOnly` / `afterStop`) vs. **Transcription speed** (`transcribeWhileRecording`) setting; if enabling `transcribeWhileRecording` by default later, **Whistle** is ready immediately on all supported devices, while **Parakeet** on 4 GB / A13 devices should await unplugged battery `%` delta verification.
4. **Optional follow-up optimization (non-blocking):**
   - `CAFPrefixPrecomputer` wrote `1,797` Whistle checkpoints over 30 minutes (~1/s). Throttling Whistle checkpoint persistence to every 10 s (matching Parakeet's checkpoint cadence) will reduce flash writes and background CPU on long recordings.

---

## 5. Hardware Caveats & Manual Follow-Up Pass (for Silvio)

AWS Device Farm handsets run in USB-powered server racks under headless `XCTest` (which cannot tap the modal iOS microphone permission alert):

- **Unplugged battery `%` delta:** Both 30-min runs reported `batteryState = charging` (`100% → 95%`). A quick unplugged 30-min battery `%` comparison (`recordOnly` vs. `transcribeWhileRecording`) on a personal iPhone is still needed before flipping any default on battery.
- **Physical microphone `AVAudioRecorder` 30-min capture under live mic permission:** `AVAudioApplication.shared.recordPermission` was `.undetermined` on headless Device Farm, so `test01`/`test03`/`test04` exercised `LiveCAFReader` + `AVCaptureAdapter` lifecycle without triggering the blocking modal alert. Verify one live-mic 30-min recording on a personal iPhone with Microphone permission granted.
- **Physical Bluetooth headset connect/disconnect & real carrier call:** Simulated `AVAudioSession` notifications passed; verify once with real AirPods/BT headset and a real carrier call.

---

## 6. Reproducing on AWS Device Farm

```bash
# Fast deterministic contract test on Simulator (always enabled in scripts/test.sh app):
scripts/test.sh app -only-testing:CassiniTests/HandsetQualificationTests

# 5-min paired qualification on a physical iPhone (AWS Device Farm, D89 $120/mo budget guard):
AWS_PROFILE=cassini-devicefarm uv run --with boto3 python3 scripts/devicefarm-qualify.py \
  --device-arn <DEVICE_ARN> \
  --pool-name d1126-iphone14pro-27.0 \
  --name d1126-iphone14pro-5min \
  --filter HandsetQualificationTests/testQualificationHarnessAndTelemetryContract,HandsetQualificationTests/test01RealCAFLiveReaderAndInterruptionLifecycle,HandsetQualificationTests/test02PairedEquivalenceAnd5MinMetrics \
  --short-seconds 300 --timeout-minutes 30

# 30-min continuous Parakeet or Whistle qualification:
AWS_PROFILE=cassini-devicefarm uv run --with boto3 python3 scripts/devicefarm-qualify.py \
  --device-arn <DEVICE_ARN> \
  --pool-name d1126-iphone11-18.6.2 \
  --name d1126-iphone11-30min-parakeet \
  --filter HandsetQualificationTests/test03ThirtyMinuteContinuousParakeet \
  --long-seconds 1800 --long-parakeet --timeout-minutes 60
```
