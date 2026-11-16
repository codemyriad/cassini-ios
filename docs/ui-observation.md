# Recording motion and UI observation audit

D-1070 audits `Features`, `Design` and `Stores`, with GitHub #161 as the symptom report.
The UI remains native SwiftUI on iOS 18+, with existing iOS 26 glass and platform shims.

## Recording

- AV capture samples `averagePower` at 40 Hz with 5 ms timer tolerance; pause stops the timer,
  successful resume restarts it, and stop/termination invalidate it. The two production `.level`
  consumers are `RecordingController` and `VoiceEnrollmentAdapter`. Both read captured elapsed
  time. Enrollment's 45-second boundary does not count events; recording policy still has its
  own one-second clock. Existing interruption, failure and storage rules are unchanged.
- `WaveformBars` retains the original 56 peak buckets of 125 ms, clamping invalid samples.
  Its latest captured timestamp also drives presentation. `WaveformAnimation` aligns peaks by
  bucket identity and interpolates fractional heights over 50 ms, retargeting from the visible
  height. Fractional scrolling uses monotonic time, clamps extrapolation to one bucket on stalled
  input, and resets on a new recording or gaps longer than the window.
- `LiveRecordingWaveform` alone observes meter samples. Its animation child contains
  `TimelineView(.animation)` and a Canvas; no fixed display-rate timer is added. Each display
  callback performs bounded scalar math and draws two paths, without rebuilding sample arrays.
  The 40 Hz sample update prepares the fixed-size interpolation arrays.
- Pause, Reduce Motion and inactive scene branches contain a static Canvas and **no timeline**.
  Returning creates a fresh clock anchor, so background/paused wall time never scrolls the history.
  Reduce Motion continues to show sampled levels without animated transitions.
- The localized microphone image label, VoiceOver image traits, brand colors and scaled height
  remain intact. The app opts into the display's supported refresh rates through
  `CADisableMinimumFrameDurationOnPhone`; iOS can still lower cadence for power/thermal reasons.
- Recording layout observes lifecycle/title/banner facts independently of elapsed/space. Timer,
  caption and waveform are separate leaves. The controller's public domain state stays intact.

## Library, playback and processing

- `LibraryScreenModel.listContent` uses a duration-free row context. It publishes structural
  invalidation for capture/queue changes, never elapsed ticks alone. Existing `content` remains
  an exact snapshot for non-UI consumers. The live row reads duration in its own view, inside
  the stable context-menu host. `renderKey` still includes all static row presentation facts;
  it does not replace rows just because duration changed. Card and capture bar remain leaves.
- The player publishes a separate `PlaybackControls` value only when transport facts change.
  The scrubber observes position; transport, failure notices, Follow chip and speaker/sample
  controls observe stable control facts. Saved voices no longer invalidates its whole list on
  sample position ticks. Active-word lookup keeps the existing sorted playback index and
  original word mapping; only affected equatable paragraph inputs change.
- Processing already separates `JobProgress` from lifecycle state. Compact status, details and
  running drafts keep their own observation boundaries. Library notices and Settings notices/
  model rows now read download progress in leaves instead of rebuilding their parent screens.
- `TranscriptCache` moved into CassiniEngine. Sealed/draft assembly and in-note search run on the
  concurrent executor, never in a view's body. View-owned tasks publish only uncancelled current
  results. Keys retain transcript timing provenance, speaker names/provenance/colors, saved voice
  names, suggestions, full draft state and search query. Theme is resolved by views from semantic
  tokens, not cached colors. The cache is per Note screen. A growing draft keeps its last prepared
  content while the next snapshot is built, avoiding temporary scroll-height collapse.
- Playback file size/modification-date reads now run off the main actor. The app's synchronous
  show command starts a preparation request; owner/generation checks prevent a departed or
  superseded screen from reopening its player. The metadata signature still detects rewritten
  files at the same path. AVFoundation session/player operations retain their platform isolation.

## Structure, accessibility and availability

- Existing `@State` model ownership, environment stores, local `@Bindable` bindings and stable
  navigation identities remain. No observable model is recreated by display callbacks.
- Voice enrollment publishes recording/busy/result transitions, no meter or duration tick. Its
  form therefore needs no extra high-frequency leaf; analysis and sample cleanup already run
  asynchronously. Saved voice sample resolution and Document info already do their disk work
  off the main actor.
- Settings retains its form sections and binding ownership. Note details and export/rename
  presentations retain their mutual-exclusion and dismissal sequencing. No presentation identity,
  accessibility identifier, localized label or Dynamic Type policy was removed.
- Search icon/buttons and Follow playback transitions now honor Reduce Motion. The shared static
  waveform avoids allocating an array of placeholder levels each time it renders.
- Availability branches in `MeetingChrome`, `OrbitMark`, text-edit adapters, model rows and Library
  presentation helpers are already focused platform components. The iOS 18 export full-screen
  presentation, text-view edit bridge, draft-scroll fallback and fixed Saturn sizing remain intact;
  no iOS 26 behavior or deployment target changed.

## Evidence and limits

Deterministic package tests cover 60/120 Hz phase math, fractional heights, bucket rollover,
retargeting, gaps/reset, invalid levels, cadence-independent peaks, static mode eligibility,
recording/player/list observation boundaries, transcript cache preparation/cancellation and key
changes. Hosted tests exercise recorder lifecycle, enrollment, playback reload/ownership and
whole-screen transcript redraw isolation. The pre-stage PR body records the exact local runs.
Tests use supplied clocks, observation callbacks, task completion and existing polling helpers;
no new fixed sleeps or wall-clock performance assertions.

Simulator functional/a11y tests do not measure physical ProMotion frame delivery, energy use or
microphone signal quality. Confirm those on a 120 Hz device with Instruments; the display rate is
system-controlled. The live meter still uses raw AVAudioRecorder power, as documented under D26.1.
Full `test.sh all`, status posting and the full iOS 18/26/27 gate are intentionally reserved for the
coordinator after the prerequisite branch merges and this pre-stage is rebased/pushed.
