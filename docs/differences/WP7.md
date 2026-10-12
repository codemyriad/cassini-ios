# WP7 — playback: differences from Android

## Same as Android

- **Controller.** `PlaybackController` (CassiniEngine `Playback/`) follows Android's `PlaybackController`: a 150 ms
  ticker; a save every 5 s while playing; final saves on pause, leave and the end of the file (the duration), run one
  at a time in the order they were asked for; open and leave by owner (`PlaybackOwner`, one per Note screen); reload
  after the audio changed at the same position and play state; a `.failed` state for a file that cannot be opened;
  speaker samples (`playRange`) that return to the position and play state from before, with Android's rules for
  nested samples, seeks, pauses, interruptions and leaving.
- **Skip interval.** 10 s, as on Android (it was 15 s), for the bar, the lock screen's `preferredIntervals` and the
  slider's VoiceOver steps (`PlaybackSkip`). SwiftUI's slider has no step count to report, so VoiceOver's adjustable
  action moves it by 10 s in place of Android's `ProgressBarRangeInfo.steps`.
- **Player bar.** Android's copy and semantics: the bar is the group "Playback"; the slider is "Position" with the
  value "11:44 of 23:50" and moves by 10 s with VoiceOver swipes; "Back 10 seconds", "Forward 10 seconds", and
  "Play"/"Pause" with the value "Paused"/"Playing". The times show the position and the total duration (no longer the
  time remaining). Dragging the slider moves only the slider and the times; the player seeks once on release. All
  targets are at least 44 pt (play/pause 64 pt, skips 52 pt).
- **The Note screen** opens the player while it shows it and leaves it when it goes away or when the note loses its
  player (a transcription starts, a recording runs). Whether it has a player and what the player follows are the pure
  `NotePlayer.hasPlayer` and `NotePlayer.key` (CassiniNotebook); the open-or-reload choice is
  `PlaybackController.show`. A file that cannot be played shows the banner "This audio can’t be played" instead of a
  global alert.
- **Failed position saves** are dropped without the global save alert ("the next one counts"):
  `LibraryStore.commit(_:reportsFailure:_:)` with `false`.

## Different on iOS

- **Opening is synchronous.** `AVAudioPlayer` opens a file at once on the main actor, where Android prepares
  `MediaPlayer` off the main thread. So an open or a reload cannot be overtaken while its file prepares, and the
  controller needs no generation counter. The Android tests about those races
  (`overlappingOpensOfTwoNotesKeepOnlyTheLastPlayer`, `aSecondScreenOfTheSameNoteKeepsItsPlayerAfterTheFirstLeaves`,
  `aNoteLeftWhileItsFileIsPreparedAgainKeepsNoPlayer`, `anOpenOfAnotherNoteDuringAReloadKeepsOnlyTheNewPlayer`) keep
  their order of events with the open finished first, and check the same outcome. One consequence: a screen that
  leaves right after its open saves the position of the note it opened (Android's overtaken open saves nothing).
- **`leave` does not wait for its save.** It queues the final save and returns; `settle()` waits for every queued
  save. Until a note's latest save has landed, `show` opens that note at the position being saved rather than the
  older one stored on the note, so a screen that comes right after a leave opens where the note was left, as
  Android's joined save gives. Going to the background calls `savePosition()` (a final save that keeps playing, iOS
  only: Android pauses on leave and has no background playback) and holds a background task until the save and the
  note write have landed.
- **A second screen of the same note.** When a screen shows the note's changed audio while another screen of the
  note owns the player, `show` moves the player to it and reloads at the live position and play state; Android's
  reload refuses a screen that does not own the player, and the owner reloads later. Moving it matches what an open
  of the same file already does, and neither screen falls back to the stored position.
- **Audio focus.** iOS has no focus requests. The adapter takes the audio session on play and gives it back on pause,
  unload and the end of the file with `.notifyOthersOnDeactivation`. `load` swaps the file and keeps the session, so
  a reload that plays on (the compressed copy replacing the capture) never hands the audio to other apps; a reload
  that does not play on gives it back, as Android abandons focus only then. Only the start of an interruption pauses
  (never its end); the system has usually paused `AVAudioPlayer` by then, so the adapter reports every start and the
  controller ignores it when nothing was playing. Losing the output in use (`oldDeviceUnavailable`, Android's
  "becoming noisy") pauses. Playback never resumes by itself. A play the system refuses stays paused, as Android does
  when focus is refused.
- **The end of the file.** The port has no completion callback; the adapter keeps its position at the end once
  `AVAudioPlayer` finishes, and the controller's ticker sees a stopped player at the end and saves the duration.
- **What a reload is keyed on.** iOS has no `document.opus` written in place and the note stores no document
  signature. The Note screen shows its player again when the note's `audioFilename` or duration changes (the
  compressed `audio.m4a` replacing `capture.caf` after a recording), when a recording's block lifts, and whenever the
  screen appears. Each time, `show` compares the file's size and modification date (`PlaybackSource.signature`) with
  the open file's and reloads when they differ. A file rewritten under the same name and duration while the screen
  stays open is not noticed until one of those happens; nothing in the app rewrites audio that way.
- **Library preview.** A final save sets `previewText` through the `NotePreview` function the app passes to
  `PlaybackStore`; `PreviewText` itself is WP1's pure rule, not in this branch. Until it is passed in, a final save
  keeps the stored preview (see the merge task below).
- **Recording.** While a recording runs (`.starting`, `.active` and `.finishing`) the player is closed
  (`setBlocked`) and nothing opens. The Note screen's player key follows the same block (`PlaybackStore.isBlocked`),
  so the player opens again as soon as the block lifts.

## iOS extras (kept)

- Playback speed (0.75–2×), kept for the next file.
- Lock-screen and headphone controls (`MPRemoteCommandCenter`: play, pause, ±10 s, scrubbing) with Now Playing
  metadata, and playback that continues in the background.
- The waveform behind the slider and the bookmark button in the bar.
- Speaker samples in the name sheet are only offered while the note's player is open.

## Merge tasks

- **When WP1 lands:** pass `preview: { note, position in PreviewText.of(...) }` to `PlaybackStore` in `AppGraph`, and
  remove the `XCTExpectFailure` from `PlaybackStoreTests.testAFinalSaveThroughTheAppRefreshesTheLibraryPreview`. That
  test runs a final save through the real graph and asserts that the preview changes. It is marked as an expected
  failure until then, and the marker makes the test fail once the preview is wired, so the step cannot be skipped.

## Ported from WP8 (merged from `phase-b`)

WP8 landed first against the old `PlaybackStore` API; the merge of `phase-b` into this branch ported its call sites:

- `AppGraph` builds `PlaybackStore(playback:library:)` (the preview argument stays for WP1); the old
  `init(playback:library:errors:clock:)` is gone. WP8's `VoicesStore(..., clock:)` is kept.
- `NameSpeakerSheet` plays a sample with `playSample(note, from: window.start, to: window.start + window.duration)`,
  offers the button only while the note owns the player (`playback.owns(noteID)`), and reads whether a sample runs from
  `playback.state.sample != nil` instead of a local `sampling` flag and `.onChange(of: playback.state.isPlaying)`.
  Toggling, closing and leaving the sheet call `stopSample()`, which never pauses ordinary playback.
- `NoteDetailView` keeps WP7's `show`/`leave` and `if ownsPlayer { playback.play() }`.
- `CassiniUITests` keeps both WP8's `row` helper and WP7's player test.
- WP8.md's "For WP7: … swap in `playRange` when it exists" is done by the sheet change above.
