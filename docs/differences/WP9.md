# WP9 — Banners, NoticeCenter, notifications, deep links

## Differences from Android

- **Kinds.** The catalogue (`BannerKind`, CassiniNotebook `Notices/`) has every Android kind that applies on iOS, with
  Android's tones, groups, actions and copy. Not on iOS: `NO_ENCODER` (Cassini always has its Opus encoder),
  `TX_MEMORY` (iOS ends an app that runs out of memory without an error Cassini can catch; a pause for memory shows as
  a pause, a `MEMORY` failure as "Couldn't transcribe" with its message), `IMPORT_WAV` (AVFoundation reads every WAV)
  and `REC_STOPPED_FILE_LIMIT` (the capture is a CAF file, with no 1 GiB M4A end). So `BannerArgs` has no `m4a` and no
  `fileLimit`. iOS only: `REC_INPUT_LOST` (headphones unplugged), `REC_COMPRESSION_FAILED` ("Saved in its original
  quality", dismissible) and `NOTES_UNREADABLE` ("2 notes can't be read", dismissible for the run). They replace
  messages the interim `NoticesStore` used to show.
- **"Paused by iOS".** Android's copy says Android paused the work for its daily limit. iOS says "iOS ended the time
  Cassini had in the background. Resume to continue where it stopped." (TX_PAUSED, TX_PAUSED_EARLY) and "iOS stopped
  the download…" (DL_STOPPED). The notification is "Transcription paused by iOS · iOS needed the time back. Open
  Cassini to resume." with no "Paused at" numbers: the job's stop reaches the queue before its last progress is saved
  (see WP4). `pausedByAndroidWithoutWordsDoesNotShowZeroTimes` is ported as "the paused notification never shows
  times".
- **Download banners.** Apple installs its speech assets and reports only a fraction, so DL_DOWNLOADING has no "296 of
  640 MB." line for them and DL_CHECKING is never shown (no file check of Cassini's own). The Library shows a
  download's failure only, as on Android; its progress is on the model download screen and the Note's processing
  card. A job's own download progress is not a Note banner (the processing card shows it).
- **Library states.** LIB_EMPTY ("No notes yet", Record and Import) and LIB_NO_MATCH replace the illustrated empty
  states; the illustration stays only for the iOS-only Starred filter with no starred notes. "Your notes can't be
  opened" (LIB_UNAVAILABLE) replaces the alert the library used to raise when it could not be read.
- **Saved voices can't be read** shows in Settings only, as on Android. The Library no longer says it at launch.
- **Note screen.** The job banners (paused, failed, checkpoint mismatch, download failures, one voice) come from
  `Notices.job`; Start over asks first ("Start over? The draft so far is discarded. Your recording is kept."). The
  Note's TX_QUEUE_HELD on a paused note is not shown (the Library shows the hold). One voice is a finished transcript
  whose speaker analysis failed (`speakerAnalysisFailure`), the iOS form of Android's "speakers not told apart"; its
  Transcribe again starts a transcribe-again job. Closed job banners stay closed while the screen is open; a closed
  final failure removes its job, as on Android.
- **Trust banners** are catalogue banners now. Their Transcribe again (audio changed, unreadable) is not offered yet:
  it needs WP6's fresh-transcript question; Play anyway is.
- **Dismissal.** RECOVERED is acknowledged in `notices.recoveredAck` (it never goes back). An import error is closed
  until the next import fails and a download failure until the next install fails, by their sources (`ImportTracker`,
  `ProcessingStore`), in memory as on Android; the `notices.importFailureAck` / `notices.downloadFailureAck` keys stay
  unused, since the failures themselves are not kept across launches.
- **RECOVERED** says the count and the duration of the latest recovered recording, as Android; the interim notice
  summed them. Open opens the latest.
- **Notifications** (`UNNotifier`). Android's results channel is one notification thread; every result is silent and
  replaces the note's earlier one (request id = note id). Android's private visibility with a public version is
  iOS's per-category hidden-preview placeholder without `hiddenPreviewsShowTitle`: with previews hidden the Lock Screen
  shows "A note was transcribed", "A note couldn't be transcribed", "Open Cassini to resume." and so on, never the
  title. "Paused by iOS" and "Transcription stopped" carry Resume (a foreground action: Cassini opens the note and
  resumes it). Results are posted only while Cassini is in the background (the coordinators check); one that lands as
  Cassini comes back is not shown over it. Typographic apostrophes are used ("Couldn’t transcribe").
- **Permission.** Asked once, at the first recording (WP3), the first Transcribe from a screen (after the job is
  queued; the queue does not wait for the answer) or the model download (WP4). NOTIFICATIONS_OFF means denied:
  before the first question nothing is off, since the Settings app has no switch to turn on yet. The permission is
  read again each time Cassini becomes active. Turn on opens Cassini's notification settings.
- **Deep links.** A notification tap opens its note by pop-or-push with the Library at the bottom; Recording, a
  full-screen cover on iOS, closes (a recording goes on). A tap that launched Cassini is kept until the launch work has
  read the notes. `cassini://recording` (the Live Activity) and `cassini://note/<id>` go through `DeepLinks.parse`.
  Android's `ACTION_VIEW` import link is iOS's `onOpenURL` of a file (WP12).

## Interface changes (for the integrator)

- `NoticeFacts.compressionFailedAt` (new field) carries the iOS-only compression notice.
- `NoticeCenter` (CassiniEngine `Notices/`): `register(_:dismiss:)`, `facts`, `library(_:)`, `settingsBanners`,
  `refresh()`, `dismiss(_:)`, `latestRecovered`, `askNotificationsOnce()`. `AppGraph.noticeCenter` registers every
  source in `registerNotices()`.
- `NoticesStore` (app) is now the Library and Settings banner facade over the center (`library(_:)`,
  `settingsBanners`, `perform(_:on:chooseFile:)`, `dismiss(_:)`); `post(_:)` is gone.
- `DeepLink` / `DeepLinks` (CassiniEngine `Navigation/`), `Router.open(link:)` and `DeepLinkHandler`
  (`Cassini/App/Router+DeepLinks.swift`), `AppGraph.handle(_:)` and `becameActive()`; `CassiniApp` has an
  `AppDelegate` that registers the notification categories and the `NotificationResponder`.
- `ProcessingStore`: takes the `NoticeCenter`, asks to notify on the first Transcribe from a screen,
  `dismissInstallFailure()`; its "Paused at…" notices are gone (the Note's TX_PAUSED banner replaces them), so
  `TranscriptionCoordinator.onPause` has no app subscriber. `jobRunning` counts a standalone speech install.
- `RecordingStore`: `compressionFailedAt`, `contribute(to:)`, `dismissNotice(_:)`; no `notices` part.
  `RecordingCopy.recovered`, `.compressionFailed` and `.banner` are gone (copy in `BannerCopy`, table Notices).
- `ImportStore.contribute(to:)` / `dismissNotice(_:)`; `ImportActivity` and `QueueHeldBanner` are gone.
- `LibraryStore.isLoaded`; `VoicesStore.loadFailed` / `isUnavailable`. `FakeNotifier.setAuthorization(_:)`.
- `SilentNotifier` is gone: the live notifier is `UNNotifier`; UI tests use `FakeNotifier(auth: .authorized)` so no
  "Notifications are off" banner shows in screenshots.
- `Banner(spec:style:onAction:onDismiss:)` and `BannerList` (`Cassini/Design/Banner.swift`) render any spec; the
  Recording screen uses `style: .onDark`. `BannerCopy` has the copy (Notices table, English and Italian).

## Tests

Ported: `BannerKindTest` (`everyKindHasItsBoardCopy`, `variantsOfTheCopy`, `usesListsExactlyTheArgumentsTheCopyReads`,
`noPlaceholderIsLeft` as hosted tests over the string table; `flagsTonesAndGroups`, `specDefaultsComeFromTheKind` in
CassiniNotebook), `NoticeCenterTest` (all seven, CassiniNotebook `NoticesTests`, with the center's merging and
dismissal in CassiniEngine `NoticeCenterTests`), `DeepLinksTest` (`parsesTheNotificationExtras`,
`theLauncherAndUnknownExtrasAskForNothing`, `aNoteNotificationKeepsPopsToOrPushesTheNote`; CassiniEngine
`DeepLinkTests`) and `ProcessingNotificationsTest` (`resultsAreReplacedPerNoteAndHideTheTitleInPublic`,
`pausedByAndroidWithoutWordsDoesNotShowZeroTimes`; hosted `NotificationTests`). The Italian copy is Android's;
`everyKindResolvesInItalian` and `italianCopyWithArguments` are WP14's, with a spot check here. Hosted
`DeepLinkHandlingTests` cover the acceptance criterion (a tap opens the note on a cold start) and Resume.
Not ported: the ongoing-notification tests (`theOngoingTextFollowsThePhase`, `timeLeftUsesTheFormsOfTheProgressCard`;
iOS has no ongoing notifications) and `theSavedCheckpointUpdatesOnlyAShownPausedNotification` (no numbers to update).
