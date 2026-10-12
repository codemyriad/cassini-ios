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
- **WP8 (`wp8` branch) against this branch.** WP7 replaces `PlaybackStore`'s API, and `wp8` still calls the old one,
  so whichever of the two merges second must port the other's call sites before it compiles. This branch also edits
  files other packages own: `NameSpeakerSheet.swift` (WP8), `NoteDetailView.swift` (WP6) and `AppGraph.swift` (WP0),
  all of which `wp8` rewrites too; expect conflicts there and resolve them as below.
  - Removed or renamed `PlaybackStore` members:
    - `init(playback:library:errors:clock:)` is now `init(playback:library:preview:)` (`AppGraph`).
    - `load(_ note:)` is gone. A screen shows a note's player with `show(_:owner:)` and a `PlaybackOwner` it keeps
      in `@State`, and gives it back with `leave(owner)` (the Note screen keys this on `NotePlayer.key`). Tests that
      only need the note open call `show(note, owner: PlaybackOwner())`. `wp8` call sites:
      `NoteDetailView.swift:78` (`.task { playback.load(note) }` and the `.onDisappear { pause() }` after it: keep
      WP7's `show`/`leave` version), `AppGraphTests.swift:380`
      (`testGoingToTheBackgroundHoldsATaskUntilThePositionIsSaved`) and `AudioPipelineTests.swift:130`.
    - `playSample(_:from:duration:)` is now `playSample(_:from:to:) -> Bool` (an end time, not a length; false when
      the note's player is not open). `wp8` call site: `NameSpeakerSheet.swift:186`, which becomes
      `playback.playSample(note, from: window.start, to: window.start + window.duration)`.
    - `cancelSample()` is now `stopSample()`, which ends a running sample (the position from before returns, paused)
      and does nothing otherwise, so it never pauses ordinary playback.
    - `play(_:from:)` only plays when the note owns the player. `wp8`'s `NoteDetailView` `play` fallback
      (`playback.play(note, from: 0)` when it does not own the player) does nothing; keep WP7's
      `if ownsPlayer { playback.play() }`.
  - The name sheet's sampling state comes from `playback.state.sample != nil` (with `playback.owns(noteID)` to offer
    the button), not from `playback.state.isPlaying` and a local `sampling` flag: a sample ends by itself at its end,
    on a pause, an interruption or a lost output, and the state already says so. `wp8`'s `toggleSample`, `close()`
    and `.onDisappear` stop a sample with `playback.stopSample()` instead of `playback.pause()`, and its
    `.onChange(of: playback.state.isPlaying)` and `sampling` flag go.
  - `wp8`'s `docs/differences/WP8.md` ("For WP7: … swap in `playRange` when it exists") is done by the step above.
