# WP7 — playback: differences from Android

## Same as Android

- **Controller.** `PlaybackController` (CassiniEngine `Playback/`) follows Android's `PlaybackController`: a 150 ms
  ticker; a save every 5 s while playing; final saves on pause, leave and the end of the file (the duration), run one
  at a time in the order they were asked for; open and leave by owner (`PlaybackOwner`, one per Note screen); reload
  after the audio changed at the same position and play state; a `.failed` state for a file that cannot be opened;
  speaker samples (`playRange`) that return to the position and play state from before, with Android's rules for
  nested samples, seeks, pauses, interruptions and leaving.
- **Skip interval.** 10 s, as on Android (it was 15 s), for the bar, the lock screen's `preferredIntervals` and the
  slider's VoiceOver steps (`PlaybackSkip`).
- **Player bar.** Android's copy and semantics: the bar is the group "Playback"; the slider is "Position" with the
  value "11:44 of 23:50" and moves by 10 s with VoiceOver swipes; "Back 10 seconds", "Forward 10 seconds", and
  "Play"/"Pause" with the value "Paused"/"Playing". The times show the position and the total duration (no longer the
  time remaining). Dragging the slider moves only the slider and the times; the player seeks once on release. All
  targets are at least 44 pt (play/pause 64 pt, skips 52 pt).
- **The Note screen** opens the player while it shows it and leaves it when it goes away or when the note loses its
  player (a transcription starts, a recording runs). A file that cannot be played shows the banner "This audio can’t
  be played" instead of a global alert.

## Different on iOS

- **Opening is synchronous.** `AVAudioPlayer` opens a file at once on the main actor, where Android prepares
  `MediaPlayer` off the main thread. So an open or a reload cannot be overtaken while its file prepares, and the
  controller needs no generation counter. The Android tests about those races
  (`overlappingOpensOfTwoNotesKeepOnlyTheLastPlayer`, `aSecondScreenOfTheSameNoteKeepsItsPlayerAfterTheFirstLeaves`,
  `aNoteLeftWhileItsFileIsPreparedAgainKeepsNoPlayer`, `anOpenOfAnotherNoteDuringAReloadKeepsOnlyTheNewPlayer`) keep
  their order of events with the open finished first, and check the same outcome. One consequence: a screen that
  leaves right after its open saves the position of the note it opened (Android's overtaken open saves nothing).
- **`leave` does not wait for its save.** It queues the final save and returns; `settle()` waits for every queued
  save. Going to the background calls `savePosition()` (a final save that keeps playing, iOS only: Android pauses on
  leave and has no background playback) and holds a background task until the save and the note write have landed.
- **Audio focus.** iOS has no focus requests. The adapter takes the audio session on play and gives it back on pause,
  unload and the end of the file with `.notifyOthersOnDeactivation`. Only the start of an interruption pauses (never
  its end), and losing the output in use (`oldDeviceUnavailable`, Android's "becoming noisy") pauses. Playback never
  resumes by itself. A play the system refuses stays paused, as Android does when focus is refused.
- **The end of the file.** The port has no completion callback; the adapter keeps its position at the end once
  `AVAudioPlayer` finishes, and the controller's ticker sees a stopped player at the end and saves the duration.
- **What a reload is keyed on.** iOS has no `document.opus` written in place. The Note screen reopens the player when
  the note's `audioFilename` changes (the compressed `audio.m4a` replacing `capture.caf` after a recording) or when the
  file's size and modification date (`PlaybackSource.signature`) differ from the open file's.
- **Library preview.** A final save sets `previewText` through the `NotePreview` function the app passes to
  `PlaybackStore`; `PreviewText` itself is WP1's pure rule. Until it is passed in, a final save keeps the stored preview.
- **Recording.** While a recording runs the player is closed (`setBlocked`) and nothing opens; the Note screen opens
  it again when the recording ends.

## iOS extras (kept)

- Playback speed (0.75–2×), kept for the next file.
- Lock-screen and headphone controls (`MPRemoteCommandCenter`: play, pause, ±10 s, scrubbing) with Now Playing
  metadata, and playback that continues in the background.
- The waveform behind the slider and the bookmark button in the bar.
- Speaker samples in the name sheet are only offered while the note's player is open.
