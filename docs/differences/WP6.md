# WP6 — Note screen: differences from Android

## Where things live

- **Pure rules** (CassiniNotebook, covered by `swift test`):
  - `Transcript/`: `TranscriptTurns` (runs of one speaker), `SpeakerTint`, `NoteTranscript` / `NoteTranscripts`
    (paragraphs, names, tints, "auto", the suggestion slot, the active-word index), `TranscriptSearch` and
    `InNoteSearch`, and `PassageEdit` (`TranscriptSegment.revised`, `Note.revisePassage`).
  - `NoteScreen/`: `NoteMode` (with `showsDraft`, `hasPlayer`, `showsReading`), `ReadOnlyReason`, `NoteChips` and
    `VersionChip`, `TranscribeAgainRule`, `NoteSubtitle`, `NoteBannerFacts`, `PlaybackFollow`, `NoteScreenState` (the
    parts of Android's `NoteViewModel` that need no store: the read-only gate, word taps, banner actions and
    dismissals, dialogs, search; each event returns a `NoteEffect`), `TranscribeRow` and `DocumentInfoFacts`.
- **App** (`Cassini/Features/Note/`): `NoteDetailView` composes the stores, keeps `NoteScreenState` and carries out
  its effects. Only `ReadingTranscript`, `NotePlayerBar`, `FollowChipHost` and `NoteBannersView` read the playback
  state, and only `RunningDraft` reads the job's progress, so a tick redraws them and nothing else. `TurnView` is
  `Equatable` over what it draws; `TranscriptCache` builds the transcript once per change of the passages, speakers,
  voices or suggestions. Strings are in `Resources/Strings/Note.xcstrings` (English and Italian).
- **Interface changes:** `NoteDetailView(noteID:query:start:)` (RootView passes the route's query and start action);
  `Router` keeps a `NoteSession` per open note (`session(_:)`, `markStarted(_:)`, `keepSearch(_:for:)`,
  `below(noteID:)`), and `Router.encodedPath` drops start actions and carries each note's search as the screen left it
  (RootView saves it whenever it changes, not only when the path does); `ProcessingStore.savedDraft(_:)` is `async`
  and reads the saved progress off the main actor; `NoteMenu` sends `NoteMenuAction`s to the screen instead of acting
  itself; the Library passes its search query when it opens a note (Android `LibraryViewModel.open`), which it did not
  before. `NoteMode.sections` orders the card, the chips and the banners. `Note.versionCount` counts versions for the
  chip and Document info alike. Naming, matching, rejecting and adding a speaker change the selected kept version
  along with the shown transcript (`Note.changeShownSpeakers`), so they add no version and do not end a run of
  passage edits; Android keeps speaker labels document-wide, so naming never changes its variant count either. The `long` UI-test seed adds a three-hour note and a note transcribed to no words.

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
  "· edited" for the version that holds passage edits, "· transcribed again" for any other later version (an
  identify-speakers run included), nothing for the first. Below a Queued card the chips come first, then the
  banners; below a failure banner, the chips follow it (Android `NoteModeBody`).
- **Read-only gate.** Any job row except one waiting for consent makes the transcript read-only (the same "Wait until
  transcription finishes"), and a document whose trust is not ok gives "Fix the transcript first: Transcribe again".
  iOS has no draft naming (speakers are told apart after the words), so Android's SAVING reason and the draft's
  renamable headers do not exist: draft headers are labels. The gate covers speaker headers, the speaker count, the
  Speakers and Transcript versions menu items and Edit passage; renaming the note is always allowed. While the gate is
  closed the suggestion cards are not shown (WP8's card writes on its own, so it cannot take the gate's dialog).
- **Banners** are WP9's catalogue banners, built for the mode by CassiniEngine's `NoteBanners.banners` (Android
  `NoteViewModel.banners`): plain audio or unplayable, the trust banner over the reading content (Transcribe again
  asks the fresh-transcript question), the job's banner (`Notices.job`, with the download failures), one voice, and
  the held queue below a paused job. Only the catalogue's dismissible kinds have a close, as on Android (a final
  failure's close removes its job); a pause for memory shows as a pause (iOS has no TX_MEMORY). iOS adds two notices
  outside the catalogue: "No speakers were detected" (the speaker step found none) and WP7's "This audio can't be
  played". One voice comes from the speaker step's failure (`speakerAnalysisFailure`, other than finding nobody), not
  from a diarization record, and offers Transcribe again as Android does.
- **Back label.** iOS keeps the system back button, so the swipe back keeps working. Its title is "Back to library"
  when the Library is below the note (`Router.below(noteID:)`); UIKit reads it from the Library's navigation item,
  which `backButtonTitle(_:)` sets. iOS 26 draws the button as a chevron, so the title is what VoiceOver reads and what
  the long-press menu shows. In split view the note is the detail's root and has no back button.
- **Header.** The title is the screen's heading; the subtitle "Today, 10:02 · 48:13" shows outside reading mode, as
  on Android. The status pill, word count and language row are gone from the header (Document info has them).
- **Active word** is drawn inverted with the attributed string's background (not a rounded rectangle 3 pt wider), and
  carries no link while active (SwiftUI draws links in the tint colour); a tap on the playing word does nothing.
- **Follow.** The active line is found from the paragraph's frame and the word's character offset within it (SwiftUI
  gives no line metrics for `Text`), then scrolled to 30 % once it leaves the top 70 %; a paragraph that is not laid
  out is scrolled to with its top at 30 %. A drag during playback pauses following and shows "Follow playback"
  16 pt above the player; 4 s after the scrolling stops, following resumes. A drag while paused leaves it on. The
  draft follows its end as on Android (Phase C, `DraftFollow`, `ProcessingBody`): the header and the progress card stay
  fixed above it while 160 pt are left for the draft, new text scrolls the end into view, a scroll that ends above the
  end stops that and one back at the end starts it again; opening the screen does not scroll.
- **Search** opens prefilled from `Route.note(query:)` (the Library's query) and scrolls to its first match, as on
  every later match, unless that match's line is in view already; without animation under Reduce Motion. It is kept
  with the navigation entry, as Android keeps it in the screen's `SavedStateHandle`: the router remembers the search
  of each open note screen, so a view SwiftUI builds again keeps it, and the stack kept with the scene carries it as
  the route's query, so a restored screen shows the search as the user left it, closed included. It goes when the
  screen leaves the stack, so the same note opened again starts with only the Library's query. The bar sits pinned
  above the transcript; the counter is announced to VoiceOver when it changes.
- **Edit passage** (iOS extra). A paragraph that spans several passages offers one "Passage at 01:23" per passage. Save
  writes only while the transcript still holds the passage as it was; otherwise the editor stays open with "This
  passage changed while you were editing." A changed text drops the passage's word times. A run of edits keeps one
  version: the first edit keeps the transcript before it ("Before passage edit", unless a kept version holds it
  already, as the transcription's does) and adds an "Edited passages" version that is then shown; later edits change
  that version in place while it is shown, so many typo fixes add one copy of the transcript, not one each, even
  when speakers are named between edits. Editing
  another version adds a new "Edited passages" version after the kept ones. While a job runs, the editor is locked and
  says why.
- **Document info** has no meeting id, and the model row names Apple's speech model ("Apple SpeechTranscriber") from
  the run's provenance record (WP5); without a record of the run that made the transcript, the transcription, model
  and speakers rows are hidden. It adds "Made by" for an imported document's vendor.
- **Start actions** (`export`, `documentInfo`, `rename`) run once when the screen appears. The router records that
  they ran (Android keeps a `started` flag in its saved state), so a screen SwiftUI builds again, e.g. on an iPad
  size-class change, does not run them again; the stack kept with the scene carries none.
- **Word links** are drawn for taps only: assistive technologies see each paragraph as its plain text
  (`accessibilityRepresentation`), one element with no stop per word, under VoiceOver and Voice Control alike.
- **Off the main actor:** the checkpoint behind a stopped job's draft and Document info's run record and file size
  are read off the main actor, then shown.
- **Not ported** (no iOS counterpart): `TurnHistoryTest` (streaming diarization windows; iOS tells speakers apart once,
  offline, after the words), the word-cache and fast-opening cases of `NoteViewModelTest` (iOS reads the transcript
  with the note; there is no paged word cache or `RecentWords`), the export and naming cases (WP13 and WP8 own them).
  Of the Compose behaviour tests, the cases with an iOS counterpart are UI tests (below); the rest are not ported:
  `ModeBehaviourTest`'s header lift (the fixed card and the 160 dp draft space are `DraftFollowTests` and the UI test
  `testTheDraftFollowsItsEndBelowTheFixedCard`; the order is the pure `NoteMode.sections`), `NoteOverlaysBehaviourTest`'s
  sheet and dialog plumbing (event emission from Compose dialogs; iOS uses system alerts and menus, and the Name,
  Merge, Versions and stop-and-trash sheets are WP8's and WP12's), `SheetBehaviourTest`'s busy "Saving…" row (iOS has
  no draft naming) and `aNoteBeingRecordedCannotMoveToTrash` (a note being recorded opens the Recording screen, not
  this one; the menu still leaves Move to Recently Deleted out for it), and `ScreenBehaviourTest`'s search-header and
  system-back cases (iOS has no system back; the search has Close).

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
stack carries no start action, `aRowStartedFromTheLibraryRunsOnceOnly` for the screen and a fresh open, the search
kept changed or closed, a search that goes with its screen) and `TranscriptRenderTests` over a three-hour note of 180
paragraphs (the list alone, and the whole Note screen over the app's player: a new active word redraws only the
paragraphs of the old and the new word, never the screen, its header or its banners; a tick inside a word redraws
nothing). Pure: two passage edits in a row keep one edited version, and the chip and Document info agree on it. UI
(`NoteScreenTests`): one element per paragraph and header and no links, the "Back to library" back button, a Library
search opening the note scrolled to its first match 60 paragraphs down, "No speech", renaming a queued note, the plain
note's menu (no Document info, no text export), word tap plays, drag and the Follow playback chip, search
"1 of 3" with wrap-around and "No matches", the read-only dialog on a queued note, Document info, and the plain-audio
banner with its subtitle.
