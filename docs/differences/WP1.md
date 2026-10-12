# WP1 — Library list, search and rows: differences from Android

## Same as Android

- **Pure rules** (CassiniNotebook `Library/`): `SearchQuery` (terms split on any whitespace, tokens of letters, digits
  and the marks after them, the last token of each phrase a prefix, every phrase must match, operators are words, a
  query with nothing searchable lists every note), `Highlighted` (the marked snippet and stored preview reader),
  `DayGroups` (Today, Yesterday, `EEEE d MMM` this year, else `d MMM yyyy`, by calendar day in the app's zone),
  `PreviewText` (160 UTF-16 units, the turn stop after 40, the playing word, punctuation dropped at a cut, a cut never
  inside a surrogate pair), `RowStatus` (Android's `NoteStatus.of` table and suffixes) and `LibraryMapping` (rows,
  sections, flat results, the stored-preview fallback cut at a word, the recording card, the transcription banner
  inputs, the transcribe item of a note's actions, final failures and the empty states). The Android tests are ported
  with `// ports:` markers: `SearchQueryTest` (16), `NoteSearchTest` (the 10 named in the plan), `DayGroupsTest`,
  `PreviewTextTest`, `NoteStatusTest`, `LibraryMappingTest` and five `LibraryViewModelTest` cases (CassiniEngine
  `LibraryScreenModelTests`).
- **Search** runs 150 ms after the last keystroke; an empty query applies at once and clears the results. The query
  is trimmed, and a query that did not change after trimming is not searched again. While searching the rows are one
  flat list, newest first, each with its day ("Monday 5 Oct, 9:41 AM"); a transcript match replaces the preview with a
  15-token snippet (`…` at the cuts), a title-only match highlights the title and shows no snippet, and a title the
  64-token title snippet cut is shown plain. Matches are weight 600 on an accent tint, so they never rely on colour.
- **Opening from search** pushes `Route.note(id, query: trimmed)`; the Note screen (WP6) starts its search with it.
  The note being recorded opens the Recording screen.
- **Row status, suffix and inline actions** follow Android's table. Resume and Try again queue the job's own kind
  (`ProcessingStore.transcribe(id, kind:, origin: .screen)`); without consent they open the model download; a final
  failure (`LONG`, a refused document, or a new version a document cannot take) opens the note instead.
- **Rename** trims, refuses a blank title ("Enter a title."), stops the field at 200 characters and saves only a
  changed title.
- **Activity area**: "Recording · <title>" (or "Recording paused · …") with the elapsed time and "Tap to return"; the
  Record button reads "Recording · 24:07" with the VoiceOver label "Return to recording"; the banner "Transcribing
  <title>" (or "Getting ready to transcribe …", "Downloading models") with the percent, a 4 pt bar and line 2 (WP5's
  time-left line, "Finishing the previous note…", "Downloading speech recognition — 46%", "Checking files — 80%") plus
  "· N more in queue". The banner opens the running note, or Settings for a download on its own. VoiceOver hears it
  when its title changes and at each 5 % step.
- **Empty states**: "No notes yet" with real Record and Import audio buttons (only once the notes were read, so it never
  flashes), "Nothing matches “q”", and "Your notes can’t be opened" when the library could not be opened, with Record
  and Import audio off and their hint saying why.

## Different on iOS

- **No FTS4.** iOS keeps the notes in `note.json` files, not SQLite. `LibraryIndex` holds each note's tokens (folded
  for case and accents, compared as bytes), worked out at the first search and kept until the note changes, and
  `SearchText.snippet` follows SQLite's `snippet()` window choice (the start, then the windows ending at each hit; the
  most phrases win; then centred). The search runs off the main actor; the main actor only builds the rows from its
  results (a hosted test checks that this part fits in a frame for a thousand notes). The tests that probe SQLite
  (`sqliteHasFts4WithUnicode61AndRemoveDiacritics`, `replacingTheCacheKeepsTheFtsDocid`) have nothing to test.
- **Bookmark labels are searched too** (an iOS extra; bookmarks are iOS-only).
- **Highlight ranges are character offsets**, not UTF-16 indices, so they map onto `AttributedString` directly.
- **A transcribed note is a "document".** Android transcribes into a Cassini document; iOS keeps the transcript in
  `note.json`. So a note with a transcript (or transcribed with no words) counts as a readable document for the status
  table, unless it was imported from a document Cassini could not read or that is newer.
- **The preview without a stored one.** `Note.previewText` is stored at each final playback save (WP7's
  `NotePreview`, now wired in `AppGraph`). A note without one shows `PreviewText` at its saved position, computed from
  only the passages it can show; an older stored preview without ellipses that fills 160 characters is cut at a word,
  as Android cuts its `substr(body, 1, 160)` fallback.
- **Speaker count and "No speech"** come from the transcript's distinct speaker ids and whether it has any word.
  "Adds version N" counts the note's saved versions (at least one when it has a transcript).
- **The actions sheet is a context menu** (long press): Star (iOS extra), Rename, the transcribe item for the job's
  state (Transcribe; Transcribe again "Adds version N." with "Speaker names carry over." when the speaker models are
  installed and a speaker is named; Stop and keep progress; Remove from queue; Resume and Start over, which asks
  first; Transcribe again shown off with "This file can’t take a new version here."), an Export submenu that opens the
  note with `start: .export(format)`, Document info (`start: .documentInfo`) and Move to Recently Deleted. While a
  note is being recorded it offers only Star and Rename. Transcribe again on a stale or unreadable document asks
  "Transcribe again?" first.
- **Accessibility.** Each row is one button labelled "title, spoken duration, day time, status[, suffix][, starred]
  [, preview]" with the named actions Resume or Try again, Rename and Move to Recently Deleted (not while recording).
  The spoken duration uses the system's unit formatter ("48 minutes, 13 seconds"). The inline Resume and Try again are
  their own 44 pt buttons ("Resume transcribing <title>", "Try transcribing <title> again"), as Android keeps them
  clickable inside the merged row. Day headers are headers. iOS has no system Back, so Back-to-clear does not apply.
- **Header.** The iOS wordmark and the serif headline stay (the headline reads "Notes" at accessibility text sizes);
  "Trash" is "Recently Deleted". The privacy line says "Transcribed on this device" because the app also runs on iPad,
  as WP4 words "Transcribe on this device".
- **Starred filter** (All / Starred, an iOS extra) with its own empty state ("Keep your favorites close.").
- **Query and filter** are kept in `@SceneStorage` (Android: `SavedStateHandle`), except for UI-test launches.
- **Import picker types** are `ImportStore.contentTypes`: `public.audio`, the `org.xiph.opus` type Info.plist declares
  (`.opus` and `.ogg`), and whatever type the system gives `.ogg`. A hosted test checks `.opus`, `.ogg`, `.m4a`,
  `.mp3` and `.wav` files are offered and a PDF is not.
- **Notices.** Until WP9's notice center renders the Library banners, the Library keeps its own empty states
  (`LibraryMapping.emptyState`, from `LibraryFacts`) and shows `NoticesStore`'s messages and the queue-held banner
  above the activity area. WP9 can take `.empty`, `.noMatch` and `.unavailable` into its catalogue.

## Interface changes (for the integrator)

- `ProcessingStore.startOver(_:)` is now `async` and returns the `TranscribeOutcome` (it had no callers), so Start over
  can open the model download when consent is missing.
- `LibraryStore.isLoaded` (the notes were read), so the empty state waits for the first read.
- `AppGraph.libraryScreen` (`LibraryScreenModel`, CassiniEngine `Library/`) is put into the environment; its effects
  go to the router and the error presenter (`LibraryNavigation.swift`).
- `AppGraph` passes `NotePreview` (`PreviewText` at the position) to `PlaybackStore`, the WP7 merge task; the
  `XCTExpectFailure` in `PlaybackStoreTests` is gone and the test checks the stored text.
- `Note.matches(_:)` and `Note.preview(matching:)` (`Library/NoteSearch.swift`) are replaced by `SearchFields`,
  `SearchQuery` and `LibraryIndex`.
- **Seed `statuses`** (`AppEnvironment.Seed`, `TestFixtures`): a frozen running job, a queued note behind it, a paused
  job with saved progress, a failed job, and notes that can't play, can't be read, are newer, and have no speech, for
  the row-status UI test. It uses the frozen transcriber of the `processing` seed.
- **`NameSpeakerSheet`** (WP8) binds its name field to local text that takes the cut name back: a computed binding
  whose setter cuts the text at 80 characters left the 81st character in the field (`TextLimitTests`).

## Tests

- Swift Testing: `Packages/CassiniNotebook/Tests/CassiniNotebookTests/Library/*` and
  `Packages/CassiniEngine/Tests/CassiniEngineTests/LibraryScreenModelTests.swift`.
- Hosted: `CassiniTests/LibraryScreenTests.swift` (picker types, the rows after launch, an unopenable library, a
  thousand notes).
- UI: `CassiniUITests/LibraryUITests.swift` (`LibraryBehaviourTest`: every row status, inline Resume and Try again, the
  controls and the banner, the recording card and button, search, the empty library, Rename and its limit, the last
  row clear of a tall bottom bar) and `CassiniUITests/TextLimitTests.swift` (`TextLimitBehaviourTest`'s voice rename,
  name field and recording title). `LibraryBehaviourTest`'s back-handling, snackbar, banner-duplicate and Android
  sheet/dialog-window tests have no iOS counterpart beyond what WP2 and these tests cover; VoiceOver's named actions
  cannot be read by XCUITest and are left to the manual accessibility pass (WP14).
