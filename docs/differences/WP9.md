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
- **Download banners.** Apple installs its speech assets and reports only a fraction, with no size and no file check
  of Cassini's own, so DL_DOWNLOADING and DL_CHECKING are catalogue-only on iOS (`appEmitted` false, copy kept): a
  job's install shows on the Note's processing card, not as a Note banner as on Android, and the Library shows a
  download's failure only, as on Android. DL_NO_SPACE says the free space the plan asks for the speech model
  (`ModelPlan`, 512 MB), on the Library for a standalone install and on the Note for a job, since iOS does not tell an
  asset's size before downloading it; with no figure its body is "Free some space and try again.", never "0 MB".
- **Library states.** LIB_EMPTY ("No notes yet", Record and Import) and LIB_NO_MATCH replace the illustrated empty
  states; the illustration stays only for the iOS-only Starred filter with no starred notes. "Your notes can't be
  opened" (LIB_UNAVAILABLE) replaces the alert the library used to raise when it could not be read.
- **Saved voices can't be read** shows in Settings only, as on Android. The Library no longer says it at launch.
- **Note screen.** The Note screen's banners are `NoteBanners.banners(_:job:mode:facts:failureText:unplayableText:)`
  (CassiniEngine), Android's `NoteViewModel.banners` over WP6's `NoteMode`: PLAIN_AUDIO ("No transcript yet.",
  Transcribe) in audio-only mode, with the LONG failure text and no Transcribe when the audio is too long to
  transcribe and none while it is still being captured; UNPLAYABLE in unplayable mode; the trust banner over the
  reading content; the job's banners (paused, failed, checkpoint mismatch, download failures, one voice); and
  TX_QUEUE_HELD below a paused job, as Android. Their buttons and close are WP6's `NoteScreenState`
  (`bannerAction(_:note:job:)`, `dismiss(_:note:job:)`): Start over asks first ("Start over? The draft so far is
  discarded. Your recording is kept."), and only the catalogue's dismissible kinds have a close. A Cassini document
  in UNVERIFIED or UNKNOWN_FORMAT takes no new version (`Note.refusesNewVersion`, Android's `transcribeAgainRefused`):
  no banner offers Transcribe again, and a failed Transcribe again is final (no Try again; closing it clears the job).
  One voice is a finished transcript whose speaker analysis failed (`speakerAnalysisFailure`), the iOS form of
  Android's "speakers not told apart"; a speaker step that found nobody is the iOS notice "No speakers were detected"
  instead. Closed banners stay closed while the screen is open.
- **Unplayable.** UNPLAYABLE's body says an imported container this device can't decode when that is the reason
  (`args.text`; Android's one reason keeps its copy). An unplayable note is in unplayable mode, as on Android: no
  player, and no transcript or trust banner even for a Cassini document. A playback error at run time keeps the
  iOS-only "This audio can't be played" notice (Android shows no banner for it).
- **Trust banners** are catalogue banners: Play anyway on TRUST_NOT_VERIFIED, and Transcribe again on
  TRUST_AUDIO_CHANGED and TRUST_UNREADABLE, which asks WP6's fresh-transcript question first.
- **Dismissal.** RECOVERED is acknowledged in `notices.recoveredAck` (it never goes back). An import error is closed
  until the next import fails and a download failure until the next install fails, by their sources (`ImportTracker`,
  `ProcessingStore`), in memory as on Android, which has no such keys; the unused `notices.importFailureAck` /
  `notices.downloadFailureAck` keys were removed in Phase C, since the failures themselves are not kept across launches.
- **RECOVERED** says the count and the duration of the latest recorded of the recovered recordings
  (`RecoveredRecording.createdAt`, Android's note `createdAt`), as Android; the interim notice summed them. Open opens
  that one. Only recovered notes still in the library count, as Android's `notes.library()`: one moved to Recently
  Deleted or deleted leaves the count, and Open never targets it. The acknowledgement compares the moment of recovery,
  so it only moves forward.
- **Failure copy.** The failure messages of the TX_FAILED banner, the "Couldn't transcribe" notification and the
  note's failure line are the Failures table. Where Android has the message (`error_*`), the English and Italian are
  Android's (for example UNKNOWN is "Something went wrong. Please try again."; the two refused document states have
  Android's own texts). The iOS-only and iOS-worded ones (formats, the speech model's languages, interruptions) keep
  their iOS English with Italian marked `needs_review` for WP14. Messages no longer repeat "your audio is kept", which
  TX_FAILED's body says. A download error's message is its own failure's, as Android's
  `ModelInstallOwner.failureOf`: no space, file check, install, else the failed download.
- **Notifications** (`UNNotifier`). Android's results channel is one notification thread; every result is silent and
  replaces the note's earlier one (request id = note id). Android's private visibility with a public version is
  iOS's per-category hidden-preview placeholder without `hiddenPreviewsShowTitle`: with previews hidden the Lock Screen
  shows "A note was transcribed", "A note couldn't be transcribed", "Open Cassini to resume." and so on, never the
  title. "Paused by iOS" and "Transcription stopped" carry Resume (a foreground action: Cassini opens the note and
  resumes it if its job is still paused, as Android; otherwise it only opens the note). Results are posted only while Cassini is in the background (the coordinators check); one that lands as
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
  `retryInstall()` (a download failure banner's Retry, Download again and Try again install the failed part again
  through WP10's `ModelInstalls`) and `dismissInstallFailure()` (`ModelInstalls.dismissFailure()`); its "Paused at…"
  notices are gone (the Note's TX_PAUSED banner replaces them), and `TranscriptionCoordinator.onPause` is removed.
  `jobRunning` counts a standalone model install. A failed standalone speech install carries the plan's
  `ModelPlan.speechInstallBytes` (`ModelInstalls`), since iOS does not tell the asset's size.
- `RecoveredRecording.init(noteID:createdAt:recoveredAt:duration:)` (new `createdAt`), `NoticeFacts.latestRecovered`.
- `NoteBanners` (CassiniEngine `Notices/`): `banners(_:job:mode:facts:failureText:unplayableText:)`, `oneVoice(_:)`,
  `noSpeakers(_:job:)`, `downloadFreeBytes`; it replaces WP6's interim `NoteBanner` / `NoteBanners.of` (CassiniNotebook),
  whose `NoteBannerFacts` stays (without `playbackFailed`). `NoteScreenState.bannerAction(_:note:job:)` takes a
  `BannerAction` and `dismiss(_:note:job:)` a `BannerSpec`; `BannerKind.trust(_:)`. `Note.refusesNewVersion` (WP6's
  `TranscribeAgainRule.refused` is gone), `DownloadError.failure`. The app's `NoteBannerView` and
  `DocumentTrustNotice` are gone: `NoteBannersView` renders a `BannerList`.
- `BannerKind.unplayable` uses `.text`. App: `Note.playbackProblem` is gone and `UnplayableReason.message` is
  `bannerText` (nil for `.interrupted`).
- `RecordingScreenModel.banner` is a catalogue `BannerSpec?` and `perform(_:)` takes a `BannerAction`;
  `RecordingBanner.Tone`, `.tone`, `.Action` and `.action` are gone (the catalogue has them). `Notices.modelDownload`
  and `Notices.downloading` are gone; `RecordingLink.matches` is gone and `DeepLinks` names its scheme and hosts.
- `RecordingStore`: `compressionFailedAt`, `contribute(to:)`, `dismissNotice(_:)`; no `notices` part.
  `RecordingCopy.recovered`, `.compressionFailed` and `.banner` are gone (copy in `BannerCopy`, table Notices).
- `ImportStore.contribute(to:)` / `dismissNotice(_:)`; `ImportActivity` and `QueueHeldBanner` are gone.
- `LibraryContent.facts` (the Library's `LibraryFacts`, with `audioOnly`) feeds `NoticesStore.library(_:)`;
  `NoticesStore.init(center:router:processing:recording:)`. `VoicesStore.loadFailed` / `isUnavailable`.
  `FakeNotifier.setAuthorization(_:)`. `SettingsAdapter` reads `notificationsOff` from the `NoticeCenter` and its
  `refreshNotices()` is `NoticeCenter.refresh()`, so Settings and the banners agree; Settings shows
  `NoticesStore.settingsBanners`.
- `SilentNotifier` is gone: the live notifier is `UNNotifier`; UI tests use `FakeNotifier(auth: .authorized)` so no
  "Notifications are off" banner shows in screenshots, and `--notifications-denied` (Settings tests) turns them off.
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
`DeepLinkHandlingTests` cover the acceptance criterion (a tap opens the note on a cold start) and Resume (a paused
transcribe-again job goes on from its checkpoint with its kind). `NoteViewModelTest`
(`pausedRowsResumeOrStartOverWithConfirmation`, `anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears`,
`aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer`, `theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges`; the
banner part, CassiniEngine `NoteBannersTests`, with WP6's NoteScreenTests keeping the modes and the dialogs), `LibraryViewModelTest` (`recoveredBannerOpensTheLatestNoteAndDismisses`,
`queueHeldBannerContinues`; hosted `NoticesStoreTests`) and `LibraryMappingTest`'s `transcribeAgainRefused` part
(CassiniNotebook `FailureRulesTests`).
Not ported: the ongoing-notification tests (`theOngoingTextFollowsThePhase`, `timeLeftUsesTheFormsOfTheProgressCard`;
iOS has no ongoing notifications) and `theSavedCheckpointUpdatesOnlyAShownPausedNotification` (no numbers to update).
