# WP2 — Recently Deleted, Undo and purge: notes for the README and later work packages

## Differences from Android

- **Name.** Android's "Trash" is "Recently Deleted" on iOS, as in Photos and Notes (kept by decision): "“title” moved to
  Recently Deleted", "Stop transcription and move to Recently Deleted?", "Recently Deleted is empty". The rest of the
  copy is Android's (Trash table, English and Italian; Italian uses "Eliminati di recente").
- **Snackbar time.** Android asks the accessibility settings for their recommended timeout for 10 s. iOS has no such
  setting: the snackbar stays 10 s, and 30 s while VoiceOver runs (`TrashPolicy.undoDuration`). Its message is also
  posted as a VoiceOver announcement, and Undo is both the 44 pt button and an action of the message.
- **Where the snackbar shows.** Every move lands on the Library, which shows the snackbar 24 pt above the capture bar.
  On regular width the Library is the sidebar, so a note moved from the detail column closes there and the snackbar
  shows at the bottom of the sidebar.
- **The stop confirmation** ("Stop transcription and move to Recently Deleted?") is presented from the root, so the
  Library's menu and the Note screen's menu share it; Android has one dialog per screen. It is not restored after
  Cassini is closed (Android keeps it in `SavedStateHandle`); the Delete now and Empty confirmations are, through scene
  storage.
- **Back label.** iOS has no system Back with "Back to library" / "Back to settings": the navigation bar shows the
  previous screen. `Route.trash` has no `from:`.
- **Dates** follow the locale: "Deleted Oct 2" in en_US where Android's English shows "Deleted 2 Oct"; the year is shown
  only outside the current year, as on Android.
- **Order of a permanent delete.** As on Android: the job (a running one is stopped and awaited), the voiceprints, then
  the directory. iOS keeps `note.json` inside the note's directory, so the directory and the "row" go together: the
  directory is first renamed to `<id>.purging` (one atomic step) and then removed, so a delete cut short never leaves
  audio without its `note.json` for the launch's rebuild to turn back into a note; the next load removes the leftover.
  WP4 had removed the job after the files; it now goes first, as Android's `cancelAndRemove`, so a restore after a
  failed delete brings the note back without its job, as Android's does.
- **Claims.** Android claims a note under its note lock; on iOS `TrashService` is main-actor and keeps the claimed ids,
  so Restore refuses a note being deleted and a delete that failed gives it back. The race tests that need two threads
  (`aRestoreRacingThePurgeNeverLosesARestoredNote`) do not apply; the interleavings at the first step are ported.
- **Unreadable saved voices.** Nothing is deleted (not even the job), the purge sets one lasting fact
  (`TrashService.voicesUnavailable`, contributed as `NoticeFacts.voicesUnavailable`) and raises no alert, however often
  it runs; the launch report keeps the failure. Delete now and Empty, which the user asks for, say why in one alert.
- **Tests that change shape.** `TrashViewModelTest#backCloses` does not apply (the system Back pops the screen).
  `PurgeOrderTest#aRebuildAfterTheFileDeleteDoesNotBringTheNoteBack` is the `.purging` rename (`NoteDeletionTests`):
  iOS has no catalogue to rebuild, but the launch rebuilds bare audio directories.

## Interface changes (for the integrator)

- `TrashStore` (app) is gone. `TrashService` (CassiniEngine `Trash/`) is in the environment and is `AppGraph.trash`;
  `TrashUndo` is `trash.undo` and also in the environment. Screens call `requestTrash(_:)` (asks first for a running
  note), `restore(_:)`, `deleteNow(_:)`, `emptyTrash()` and `purgeExpired()`; the last three throw `TrashError`.
- Ports in `Trash/TrashPorts.swift`: `TrashNotes` (`LibraryStore`), `TrashQueue` (`ProcessingStore`), `VoiceEvidence`
  (`VoicesStore`; WP8 may move it to `VoiceStore`) and `TrashHost` (`AppTrashHost`: recording, player, router,
  settings), conformed in `Cassini/Adapters/TrashAdapters.swift`. Fakes in `CassiniEngineTesting/Fakes+WP2.swift`.
- `ProcessingStore.stopForDelete(_:)` is removed; `forget(_:)` is the delete's first step.
- `NoteRepository.delete` renames before removing, and `load` removes `<id>.purging` leftovers.
- CassiniNotebook `Trash/`: `TrashPolicy.isExpired`, `purgeCutoff`, `undoDuration`; `TrashDay`, `TrashItem`,
  `TrashedNote`, `TrashLabels.items`; `TrashDialogRequest` / `TrashDialog`.
- `LibraryView` gains `.trashUndoSnackbar()` (before its capture-bar inset) and `RootView` `.trashStopConfirmation()`;
  `NoteActionsMenu` and `NoteMenu` call `requestTrash`. `Cassini/Design/Snackbar.swift` is the shared snackbar for WP9.
- WP10: a Settings row for Recently Deleted can show `trash.items.count`.

## Tests

Ported: `TrashPolicyTest` (all), `TrashViewModelTest` (the cards, restore, the dialogs and their storage, empty),
`PurgeOrderTest` (`eachStepRunsBeforeTheNext`, both crash cases, `aRestoreAfterTheTrashSnapshotKeepsTheNote`,
`anExpiredNoteRestoredAndTrashedAgainIsNotPurged`, `aRestoreDuringThePurgeOfTheSameNoteIsRefused`,
`aRestoreAfterAFailedPurgeBringsTheDocumentBackWithoutItsVoices`), `LibraryViewModelTest`
(`trashShowsTheSnackbarAndUndoRestores`, `trashOfARunningNoteAsksFirst`, also as UI tests) and `NoteRepositoryTest`
(`trashRecordsTheJobAndRestoreRequeuesAQueuedOne`, `purgeExpiredDeletesOnlyNotesWhoseDaysAreOver`). Hosted tests check
the launch purge, unreadable voices and Undo over the real graph; the UI tests `testTrashAndRestore` and
`testEmptyTrashRequiresConfirmationAndRemovesRecording` are updated, and Delete now, Undo and the running-note
confirmation have their own.
