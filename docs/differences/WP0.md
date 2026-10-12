# WP0 — architecture foundation: notes for the README and later work packages

## Differences from Android

- **Navigation.** Settings, Recently Deleted, Saved voices, Licenses and the model download are pushed routes, as on
  Android; Recording is a full-screen cover. On regular width (iPad, large iPhones in landscape) the Library is a
  sidebar and the note opens beside it (`NavigationSplitView`); on compact width it is one stack. The stack is saved
  with the scene and restored on the next launch.
- **Back labels.** iOS has no system Back. `Router.below(_:)` / `BackStack.below` give the screen under a route, for
  the labels Android picks the same way (`DeepLinksTest#theKeyBelowAScreenPicksItsBackLabel`).
- **Settings storage.** Android keeps its small settings in a DataStore file; iOS keeps them in `UserDefaults` under
  the same key names (`models.consentAt`, `queue.hold`, `notices.recoveredAck`, …; see `SettingsKeys`). Timestamps are
  epoch milliseconds, as on Android. The queue hold is stored as `user` / `system`.
- **Speech-model consent** is a timestamp (`models.consentAt`), as on Android. The old `modelDownloadsAllowed` and
  `speakerDownloadsAllowed` switches migrate to consent at first launch and are then removed.
- **Palette.** The warm iOS palette (paper, card, ink, muted, ember) stays the brand; tone tints (ok, info, warn,
  error, plain) and speaker tints are added in `Cassini/Design/Tokens.swift`. Contrast is checked by WP14.
- **Clock name.** The port is `AppClock`, not `Clock`, because Swift's standard library already has a `Clock`.

## Where things live (for later work packages)

- **Ports** (`Packages/CassiniEngine/Sources/CassiniEngine/Ports`) are frozen. `Transcribing` and `SpeakerAnalyzing`
  report typed events (`TranscriptionEvent`, `SpeakerAnalysisEvent`) rather than strings; the app words them.
  `AudioProcessing` (inspect, compress, decode Opus) was added so file-level audio work stays behind a port.
- **Data-only states** are in CassiniNotebook so the pure rules and the widget can use them: `ProcessingState`
  (`Progress/`), `RecordingState` and `RecordingActivityState` (`Recording/`), `PlaybackState` (`Playback/`),
  `NoticeFacts` (`Notices/`).
- **Placeholder coordinators.** Today's queue, recording and playback behaviour runs in the app stores
  `ProcessingStore`, `RecordingStore` and `PlaybackStore` on top of the ports. WP4, WP3 and WP7 build
  `TranscriptionCoordinator`, `RecordingController` and `PlaybackController` in CassiniEngine and make these stores thin.
  Import and export placeholders are `ImportStore` (WP12) and `ExportStore` (WP12/WP13); trash is `TrashStore` (WP2).
- **SettingsStore** is in CassiniEngine (`Stores/SettingsStore.swift`), not the app, so `swift test` covers it; WP10
  owns it from here.
- **Startup.** `Startup` runs hooks in fixed slots: `load`, `recover` (WP3), `reconcile` (WP4), `voiceLinks` (WP8),
  `purge` (WP2), `sweep` (WP13). `AppGraph.registerStartup()` is where each WP adds its hook.
- **Notices.** Until WP9's `NoticeCenter`, `NoticesStore` keeps every message until it is dismissed; a new one never
  replaces another.
- **Live Activity.** `CassiniShared/RecordingActivityAttributes.swift` is compiled into the app and, once WP3 adds it,
  the `CassiniActivity` extension; `LiveActivityIntent`s go in the same folder. `project.yml` changes go through WP0.
- **Test fakes** are in the `CassiniEngineTesting` product. The app imports it only in Debug, for UI-test launches;
  Release builds never reference it.
- **UI-test launches.** `--ui-testing` uses its own library folder and preferences suite, a clock fixed at Thursday
  8 October 2026 09:41 UTC, en_US formatting and fake transcription. Named seeds: `--seed library|search|speakers|
  trash|voices|processing|recording` (`--seed-test-data` is `library`); `processing` freezes a job at 62 %, `recording`
  uses a fake microphone. `--open-fixture [note id]` opens the given note, or the newest.
- **Hosted tests** build an `AppGraph` over a temporary root and a fresh `UserDefaults` suite (`CassiniTests/TestGraph.swift`).
