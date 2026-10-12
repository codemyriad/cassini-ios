# WP6 — Note screen: differences from Android

## Where things live

- **Pure rules** (CassiniNotebook, covered by `swift test`):
  - `Transcript/`: `TranscriptTurns` (runs of one speaker), `SpeakerTint`, `NoteTranscript` / `NoteTranscripts`
    (paragraphs, names, tints, "auto", the suggestion slot, the active-word index), `TranscriptSearch` and
    `InNoteSearch`, and `PassageEdit` (`TranscriptSegment.revised`, `Note.revisePassage`).
  - `NoteScreen/`: `NoteMode` (with `showsDraft`, `hasPlayer`, `showsReading`), `ReadOnlyReason`, `NoteChips` and
    `VersionChip`, `TranscribeAgainRule`, `NoteSubtitle`, `NoteBanners`, `PlaybackFollow`, `NoteScreenState` (the
    parts of Android's `NoteViewModel` that need no store: the read-only gate, word taps, banner actions and
    dismissals, dialogs, search; each event returns a `NoteEffect`), `TranscribeRow` and `DocumentInfoFacts`.
- **App** (`Cassini/Features/Note/`): `NoteDetailView` composes the stores, keeps `NoteScreenState` and carries out
  its effects. Only `ReadingTranscript`, `NotePlayerBar`, `FollowChipHost` and `NoteBannersView` read the playback
  state, and only `RunningDraft` reads the job's progress, so a tick redraws them and nothing else. `TurnView` is
  `Equatable` over what it draws; `TranscriptCache` builds the transcript once per change of the passages, speakers,
  voices or suggestions. Strings are in `Resources/Strings/Note.xcstrings` (English and Italian).
- **Interface changes:** `NoteDetailView(noteID:query:start:)` (RootView passes the route's query and start action);
  `Router.encodedPath` drops start actions (`Route.withoutStart`); `ProcessingStore.savedDraft(_:)` reads the saved
  progress for the read-only draft; `NoteMenu` sends `NoteMenuAction`s to the screen instead of acting itself.

## Differences from Android

- **Turns from passages.** iOS notes keep passages (`TranscriptSegment`) with optional word times, not one word list
  with a speaker per word. The screen flattens the shown version's passages into words (`Note.transcriptWords`); a
  passage without word times (an edited one) is one word of its whole text, so it plays and highlights as one piece.
  Apple's words carry their own spacing: a word is joined to the one before only when the source wrote no space
  between them and it starts with closing punctuation. Paragraph ids, the 200/120-word rule and the active-word
  search are Android's. Character ranges (search, active word) count Swift characters, not UTF-16 units, so a
  decomposed "é" is one character (`aDecomposedAccentKeepsTheRangeOnTheSourceText` checks `0..<4`).
- **Passages without a speaker** (unassigned in the editor) show as "Unknown speaker" in amber; their header is not a
  button. Android words always have a speaker.
- **Reading mode** is any note with a transcript, a note transcribed to no words (`status == .ready`), or one imported
  from a Cassini document (Android: the DOCUMENT audio kind). The chips row shows on all of them; the trust chip only
  for documents. The speaker count is a button that opens the note's Speakers list (iOS extra; Android shows a
  caption). The version chip counts kept versions (`Note.versions`): "· speakers merged" for the merge's version,
  "· transcribed again" for any later version (an identify-speakers run included), nothing for the first.
- **Read-only gate.** Any job row except one waiting for consent makes the transcript read-only (the same "Wait until
  transcription finishes"), and a document whose trust is not ok gives "Fix the transcript first: Transcribe again".
  iOS has no draft naming (speakers are told apart after the words), so Android's SAVING reason and the draft's
  renamable headers do not exist: draft headers are labels. The gate covers speaker headers, the speaker count, the
  Speakers and Transcript versions menu items and Edit passage; renaming the note is always allowed. While the gate is
  closed the suggestion cards are not shown (WP8's card writes on its own, so it cannot take the gate's dialog).
- **Banners** are drawn by the screen (`NoteBannerView`) until WP9's catalogue exists; every one has Dismiss, which
  hides it by id (a final failure removes its job, as on Android). iOS adds "No speakers were detected" (the speaker
  step found none) and WP7's "This audio can't be played". A model download failure inside a job shows as "Couldn't
  transcribe" with the failure's text rather than Android's DL_* banners; the "paused by the system" body names iOS.
  One voice comes from the speaker step's failure (`speakerAnalysisFailure == .speakers`), not from a diarization
  record, and offers Transcribe again as Android does.
- **Back label.** iOS keeps the system back button, so the swipe back keeps working; its label is the system's, not
  "Back to library".
- **Header.** The title is the screen's heading; the subtitle "Today, 10:02 · 48:13" shows outside reading mode, as
  on Android. The status pill, word count and language row are gone from the header (Document info has them).
- **Active word** is drawn inverted with the attributed string's background (not a rounded rectangle 3 pt wider), and
  carries no link while active (SwiftUI draws links in the tint colour); a tap on the playing word does nothing.
- **Follow.** The active line is found from the paragraph's frame and the word's character offset within it (SwiftUI
  gives no line metrics for `Text`), then scrolled to 30 % once it leaves the top 70 %; a paragraph that is not laid
  out is scrolled to with its top at 30 %. A drag during playback pauses following and shows "Follow playback"
  16 pt above the player; 4 s after the scrolling stops, following resumes. A drag while paused leaves it on. The
  draft does not auto-scroll to new text (Android scrolls the end of the draft into view while the card stays), so the
  card always stays in view.
- **Search** opens prefilled from `Route.note(query:)` and is kept with the scene (`@SceneStorage`, per note). The bar
  sits pinned above the transcript; the counter is announced to VoiceOver when it changes.
- **Edit passage** (iOS extra). A paragraph that spans several passages offers one "Passage at 01:23" per passage. Save
  writes only while the transcript still holds the passage as it was; otherwise the editor stays open with "This
  passage changed while you were editing." A changed text drops the passage's word times. The edit keeps the
  transcript before it as a version ("Before passage edit"). While a job runs, the editor is locked and says why.
- **Document info** has no meeting id, and the model row names Apple's speech model ("Apple SpeechTranscriber") from
  the run's provenance record (WP5); without a record of the run that made the transcript, the transcription, model
  and speakers rows are hidden. It adds "Made by" for an imported document's vendor.
- **Start actions** (`export`, `documentInfo`, `rename`) run once when the screen appears; the stack kept with the
  scene carries none, so a restored screen does not run them again (Android keeps a `started` flag in its saved
  state).
- **Not ported** (no iOS counterpart): `TurnHistoryTest` (streaming diarization windows; iOS tells speakers apart once,
  offline, after the words), the word-cache and fast-opening cases of `NoteViewModelTest` (iOS reads the transcript
  with the note; there is no paged word cache or `RecentWords`), the export and naming cases (WP13 and WP8 own them),
  and the Compose-only cases of `ModeBehaviourTest`, `NoteOverlaysBehaviourTest` and `SheetBehaviourTest` (the sheets
  and dialogs here are system sheets, menus and alerts; the Name, Merge and Versions sheets are WP8's).

## Tests

Ported in CassiniNotebook: `TranscriptTurnsTest` (3), `SpeakerTintTest` (5), `NoteTranscriptsTest` (8, the draft
case without names, automatic names or suggestions), `NoteMappingTest#documentInfoNamesTheSpeechModel` (Apple's model
name), and from `NoteViewModelTest`: `theModeFollowsTheJobAndTheDocument`,
`aPlainNoteIsAudioOnlyAndAnUnplayableOneHasNoPlayer`, `aJobRowMakesTheSealedTranscriptReadOnly`,
`aDocumentThatIsNotOkCannotBeRenamedAndTranscribesFresh`, `theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges`,
`aWordTapSeeksAndPlaysAndFollowModeResumes`, `theActiveWordFollowsThePlayerPosition`,
`searchFromTheLibraryIsPrefilledAndStepsThroughMatches`, `aDocumentWithNoWordsSaysSoOnlyWhenItsTranscriptHasLoaded`,
`aNoteTrashedElsewhereClosesTheScreen`, `pausedRowsResumeOrStartOverWithConfirmation`,
`anUnverifiedDocumentOffersNoTranscribeAgainAndItsFailureClears`, `documentInfoReadsTheDocumentFactsWhenOpened`;
`ScreenBehaviourTest`'s drag cases as pure `PlaybackFollow` tests and as UI tests. Hosted: `RouterTests` (a restored
stack carries no start action, `aRowStartedFromTheLibraryRunsOnceOnly`) and `TranscriptRenderTests` (a new active
word redraws only the paragraphs of the old and the new word; a tick inside a word redraws none). UI
(`NoteScreenTests`): one element per paragraph and header, word tap plays, drag and the Follow playback chip, search
"1 of 3" with wrap-around and "No matches", the read-only dialog on a queued note, Document info, and the plain-audio
banner with its subtitle.
