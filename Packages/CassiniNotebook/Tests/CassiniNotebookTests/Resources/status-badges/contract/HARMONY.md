# Harmony contract: Cassini for GNOME and Cassini for macOS

Owner: the coordinator (Claude, acting for Silvio). Agents propose changes in their INBOX reply or in a PR, never by
diverging in code. The design canvas "Cassini recording" is the source of truth. Its frozen export is in `design/`:
- `design/png/NN-<page>-<Board>[-mac].png` is the visual.
- `design/source/<Board>.dc.html` has the exact copy and tokens. A `*-mac.dc.html` file only wraps the base board with
  `platform="mac"`. Each base board holds both platforms behind `mac` / `gnome` switches.

Silvio's resolved comments on the canvas:
- Transcription happens on this computer only. There is no remote/server option anywhere.
- Export offers exactly two formats: "Cassini file" and "Markdown".

If the canvas and an older document (SPEC-CONTROL "Product behavior", ADVISOR-APP-CONTROL item 3, DIRECTION 1/2,
APP-CONTROL UX notes) disagree, **the canvas wins**.

## 1. One product, two native skins

A person who uses both apps should find the same:
- words
- states
- errors and their actions
- confirmations
- formats
- keyboard concepts
- Library folder
- export results

Only the chrome differs: window decorations, settings window type, dialog alignment, menu bar extra vs notification,
shortcut glyphs, system fonts and accent. Everything in sections 2–9 is shared verbatim unless a row says otherwise.
Section 10 lists the only allowed platform differences.

## 2. Vocabulary (user-facing text only; code identifiers are free)

| Concept | Say | Never say in UI |
|---|---|---|
| main view | Library | Meetings window, Documents, Browser Meetings |
| one recording | meeting | session, recording folder, track, file (except "Cassini file") |
| start / stop | Record / Stop ("Stop Recording" only as the Mac menu-bar item) | New Recording…, Stop and Save, Record this computer, Record Meeting |
| your mic | Your microphone / Me | Microphone input, mic track |
| remote side | The others; this computer's sound | Desktop audio, System output, Output audio, selected processes |
| browser path | Listening inside your browser; browser companion | extension, native host, control host, WebRTC |
| transcribe (verb) | write down / written down | transcribe, as a verb in sentences. Allowed: the badge "Transcribing · …" (and the provisional current ETA fallback labels), the Settings tab "Transcription", "Back to Transcription settings" |
| diarization | Tell speakers apart | diarization, speaker embedding |
| voiceprint | saved voice / voiceprint; "voice profile" only in confirmation 2 | embedding |
| storage | Music/Cassini | any path picker for recordings |

Never shown to a person: Hz, channels, PID, SHA-256, schema, fingerprint, raw GStreamer/AVFoundation/OS error text,
".opus" as a word, "Unknown Speaker", "Audio Does Not Match", "Open a Meeting".

Typography:
- Typographic apostrophes and quotes everywhere: ’ “ ”. The canvas mixes "Let's" and "Let’s"; normalise to ’.
- en-GB spelling: Recognise, recognised.

## 3. Meeting state (shared model, one badge)

The state is stored as independent fields. The badge is derived from them.

```
lifecycle   : recording | saving | saved
origin      : own | received
interruptedAtMs : null | integer      (capture ended without Stop; gap/crash/kill recovery)
transcript  : none | queued | running | done | failed | damaged
etaMinutes  : integer, only while queued/running
error       : null | { id, action }   (an entry of section 5)
```

The badge is the first matching row, top to bottom:

| Condition | Badge text (exact) | Tint |
|---|---|---|
| lifecycle = recording | `Recording 12:48` (live timer, section 6; dot glyph) | red |
| lifecycle = saving | `Saving…` (spinner) | neutral |
| transcript ∈ {queued, running} | `Transcribing · 4 min` for positive ETA (spinner; provisional variants below) | neutral |
| error ≠ null **and** error.action ≠ null | `Needs attention` | amber |
| interruptedAtMs ≠ null | `Interrupted` (alert glyph; position in the meeting) | amber |
| origin = received | `Received` (incoming glyph, transparent fill and line outline) | outline |
| otherwise | *(no badge)* | — |

L-25/L-26 additionally define `Importing…` (neutral, spinner) on an active transient import entry. It is not a new persisted lifecycle. Cross-domain priority against an existing meeting is not drawn: **PROVISIONAL, pending Alex; current value is no shared importing lifecycle or cross-domain rule**. The existing meeting precedence above is unchanged. The independent `entryVectors` array covers the Importing badge without inventing that priority.

Positive ETA uses catalog `states.badge.transcribing`, including one minute (`Transcribing · 1 min`). **PROVISIONAL, pending Alex:** zero minutes retains `Transcribing, less than a minute left`; absent/invalid ETA retains `Transcribing…`. Do not turn those into a new compact label without a decision.

Every badge is a pill, weight600, tabular digits, with its glyph. Needs attention also has an alert glyph. Tone ids `accent` and `grey`, and the legacy `dot` boolean, are removed from v3 badge output; no compatibility aliases. Current model identifier `needsAttention` is retained (canvas visual name `attention`); code identifiers remain free under section2.

What the person can do (canvas "States" board):
- recording: rename, add a note, Stop.
- saving: nothing; the audio is already safe.
- transcribing: play, rename, read the transcript as it grows.
- ready: everything.
- interrupted: everything, on what was captured. This is history, not an error.
- received: everything except writing it down again.
- needs attention: the one action named in its line.

Rules:
- Interrupted meetings are written down like any other. They show the Transcribing badge while that runs, then "Interrupted". The position-bearing current copy is `meeting.interruptedAt`, outside the badge.
- A received meeting whose file has no transcript may be written down once. "Except writing it down again" only
  blocks a second time.
- Clearing an error removes the badge; the meeting then shows whatever the other fields give.
- The vectors in `vectors/states/states-vectors.json` version 3 are binding. Apps run both meeting and transient-entry cases. See [Status badges](STATUS-BADGES.md) for L-25/L-26, glyphs, catalog ids and explicitly provisional current values.

## 4. Library folder

- The Library is `~/Music/Cassini` on both platforms. This is literal, not `$XDG_MUSIC_DIR`, because both browser hosts
  hard-code it today.
- "Choose folder", Move Library (confirmation 3) and the "drive not connected" banner come in a later milestone, once
  the hosts read a shared Library-location config.
- There is **no save dialog for recordings**. Record writes into the Library.
- Footer line on first run (exact): "Recordings and transcripts stay on this computer, in Music/Cassini."
- Ownership of the files:
  - `session.json` and the WAV files are **capture-owned**: written by the browser host or native recorder only.
  - The apps write their own data to an app-owned `meeting.json` next to them: title, notes, speakers and names
    with provenance, transcript status, error.
  - A per-app index or cache is rebuildable and never authoritative.
- Received files are copied into the Library: `Received-<uuid>/` holding the original `.opus` plus `meeting.json`
  (with `received: {originalName, originalFolderName?, sha256}`). Duplicates are detected by sha256.
- Voiceprints never go in the Library. They live in app data:
  - GNOME: `$XDG_DATA_HOME/cassini/voices`
  - Mac: `~/Library/Application Support/Cassini/voices`
- The Mac agent drafts the exact layout in `ux-draft/LIBRARY.md` and `ux-draft/meeting.schema.json` (wave 1).

## 5. Errors: one line, one action, never a dialog

Errors are amber lines and info lines are accent-tinted. A line has: an icon, the line, an optional "when" subline
(debug/test only, not shown), and one action button.

Where a line appears:
- Under the Meeting headline and under the Library preview H1.
- The Library offline banner is the one exception (a banner).
- During a recording, the line also appears on the Recording page.

Lines are never shown as an AdwToast, NSAlert, AdwAlertDialog, toast or raw text.

| id | Line (exact) | Action | Platforms |
|---|---|---|---|
| mic-silent | No sound from your microphone. | Check sound settings | both |
| mic-silent (Recording page row) | No sound from your microphone. Check your sound settings. | Check | both |
| others-permission | The others are not being recorded. Allow Cassini to record this computer’s sound. | Open System Settings | mac |
| disk-low | Only {n} minutes of space left. | — (D7: warn below 30 min; stop and keep at the reserve) | both |
| disk-stopped | Cassini stopped recording to keep some space free on this computer. Everything up to now is saved. | — (draft) | both |
| transcribe-failed | Could not write this meeting down. The audio is fine. | Try again | both |
| model-download-failed | Could not download {model}. Whistle keeps writing down your meetings. | Retry | both |
| others-fallback (info) | Recording the others from this computer’s sound. | Why? | both |
| transcript-damaged | This file’s transcript is damaged. The audio plays. | — | both |
| library-offline (banner) | Your Library is on a drive that is not connected. | Choose folder | both, later milestone |

Errors that exist in code today and have no drawn line yet: export failed, a file that cannot be opened or imported,
playback failed, microphone permission declined, Connect failed, device changed mid-recording.
- The coordinator adds their copy to `ux-draft/strings.json` **before** the milestone that replaces the old toasts or
  alerts.
- Until then, keep the existing behaviour. Do not invent copy.

## 6. Formats (binding vectors: `ux-draft/format-vectors.json`)

- Formatting is fixed English (en-GB patterns) with a 24 h clock. Both apps are English-only today.
- The time zone is the system time zone. The vectors pass `tz` explicitly.
- Position in a meeting: `00:14:32`. Always HH:MM:SS, zero-padded, floored to whole seconds. This replaces GNOME's
  m:ss and the Mac's formatClock.
- Live timer:
  - big timer and notification: `00:12:48`
  - badge and header pill: `12:48`, minutes unpadded, `1:02:48` from one hour on.
- Duration of a meeting: `52 min`, `1 h 03 min`. Under a minute: `under 1 min`.
- Talk time: `9 min 40 s`.
- Confirmed speech: `4 h 12 min confirmed speech`.
- Day group header: `Today` / `Yesterday` / `Friday 23 October`, with the year appended when it is not this year.
- Preview subtitle: `Today, 09:00 · 52 min`; for a received meeting, `Friday 23 October, 15:00 · 34 min · Received`.
- Search result date: `Today` / `Yesterday` / `20 October`.
- Search context subtitle: `Today, 09:00 · 52 min · at 00:14:32`.
- Row meta:
  - `{duration} · {names}`. Names are in order of first speaking, unnamed speakers are `Speaker n`, and the list
    stops after 3 names with `+{k}`.
  - The canvas shows "2 speakers"/"3 speakers" in two places; that is normalised to names.
  - While recording: meta `Listening inside your browser`, line `Your microphone and the meeting in your browser`.
    Variants for other capture paths are pending (section 11).
- Row quote line: the turn the person last played or searched from, else the longest turn in the first 10 minutes.
  It is shown in “typographic quotes”.
- Skips: 10 seconds. The buttons are labelled "Back 10 seconds" and "Forward 10 seconds".
- Player: elapsed `00:03:12` and total `00:47:05`, never the remaining time. Rate shows `1×`.
- Following the transcript is implicit; there is no Follow-along switch.
- Sizes: `17 MB`, `640 MB download`, `about 24 MB`.
- Plurals: `less than a minute left` (0) / `about 1 minute left` / `about {n} minutes left`; `1 place in 1 meeting` / `{n} places in {m} meetings`;
  `1 person.` / `{n} people.`

## 7. Confirmations: only these three (Esc = secondary, Return = primary)

| # | Title | Body | Secondary | Primary |
|---|---|---|---|---|
| 1 | A recording is running | Stop and keep it, or keep recording in the background? | Keep recording | Stop and keep it |
| 2 | Delete {name}’s voice profile? | Cassini will no longer recognise {name} in new meetings. Names already in transcripts stay. | Cancel | Delete (destructive) |
| 3 | Move the Library while recording? | The meeting being recorded moves to the new folder when you press Stop. | Cancel | Move Library |

- Confirmation 1 appears when the person closes the window or quits while a recording runs. That replaces today's
  auto-stop on close and silent keep.
- "Forget everyone…" uses confirmation 2's shape. Its copy will be in strings.json.
- Deleting a meeting moves it to the Trash with no confirmation (D29). GNOME shows one undo toast for 5 s and trashes
  when it closes; macOS offers Edit › Undo Move to Trash (⌘Z) and shows no toast.

## 8. Keyboard

| Action | GNOME | macOS |
|---|---|---|
| Record / Stop (in the app) | Ctrl+R | ⌘R |
| Record / Stop (anywhere) | Ctrl+Alt+R (GlobalShortcuts portal) | ⌥⌘R |
| Search every meeting | Ctrl+F | ⌘F |
| Export… | Ctrl+Shift+E | ⇧⌘E |
| Preferences / Settings | Ctrl+, | ⌘, |
| Play/Pause; back/forward 10 s | Space; ← / → | Space; ← / → |
| Next / previous turn (while listening, D70) | Alt+↓ / Alt+↑ | ⌥⌘↓ / ⌥⌘↑ |
| Next / previous speaker (while listening, D70) | Alt+Shift+↓ / Alt+Shift+↑ | ⌥⇧⌘↓ / ⌥⇧⌘↑ |
| Play this turn (focused transcript turn, D70) | Shift+Enter | ⇧↩ |
| Stop listening (D70) | Esc | Esc |
| Back to Library | Alt+← | ⌘[ |
| Close window / Quit | Ctrl+W / Ctrl+Q | ⌘W / ⌘Q |
| Move to Trash (Library row or open meeting) | Delete | ⌘⌫ |

- D70 listening shortcuts are disabled while editing text. Escape belongs first to a dialog or popover, then search, then an overlay speaker pane; it stops listening only after those have had it.
- Close and quit show confirmation 1 while recording.
- On both platforms, Settings › Recording shows the global shortcut with one "Change…" action. GNOME opens the portal's
  ConfigureShortcuts; Mac opens an in-app recorder.
- In-meeting find is removed on both platforms: Ctrl+F/⌘F always means "Search every meeting", and a result opens the
  meeting at that point.
- Removed on both platforms: New Window, New Recording…, Browser Meetings shortcut, Follow along, Jump to current,
  Inspector, speed shortcuts, find next/previous, 5 s and 15 s skips, Ctrl+E.
- The GNOME shortcuts dialog and the Mac menus list exactly this table.

## 9. Export (boards 21/22)

- Title: `Export “{title}”`. Subtitle: "Export is the only way a meeting leaves this computer."
- "What to export":
  - **Cassini file** (default): "Audio with the transcript inside. Plays in any audio player.", with the size
    `about {n} MB`.
  - **Markdown**: "The transcript as a text file, with speakers and times."
- "Speaker names": "The file carries the names in this meeting, including {name}, who was recognised automatically.
  Voiceprints are never exported." With no recognised names: "The file carries the names in this meeting. Voiceprints are
  never exported." With two or more: "…including {names}, who were recognised automatically. …", with the names semibold
  and joined as "Dario and Ana" or "Dario, Ana and Lea" (no Oxford comma; only the names are semibold).
- "Save to **Documents**", with "Choose…" next to it. Buttons: Cancel, Export.
- Entry points: the header "Export…" button, the menu item "Export…" and the shortcut.
- Removed on both platforms:
  - Mac ShareLink, Plain Text, WebVTT, SRT
  - GNOME TXT, WebVTT, Ctrl+E
- The Markdown output is byte-identical between the apps. The golden file is `ux-draft/export/budget-review.md`
  (coordinator, wave 2).

## 10. Allowed platform differences (and only these)

| Area | GNOME | macOS |
|---|---|---|
| Main window | AdwNavigationSplitView. Sidebar header: Record (or the live pill) at start, search toggle at end. Content header: centred "Library", primary menu, close. | NavigationSplitView. Traffic lights; Record (or the live pill) at the leading edge of the sidebar. Detail toolbar: bold leading "Library", trailing search field. |
| Toolbar Record button | red fill (`#c01c28`), white dot, white "Record" | grey fill (`#e8e8ed`), red dot, dark "Record" |
| First-run Record button | big red pill on both | big red pill on both |
| First run layout | single pane, no sidebar. Header: Record, "Library", menu, close. | single pane, no sidebar. Header: Record, "Library". |
| Search field | revealed by the sidebar toggle, placeholder "Search every meeting" | toolbar field with placeholder "Search"; accessibility label "Search every meeting" |
| Selected row | grey selection (`#d4d4da`) | accent fill (`#0063d1`), white text |
| Meeting header title | centred | leading |
| Dialogs | AdwDialog / AdwAlertDialog; centred title and body; equal-width buttons | sheet under the toolbar; leading title and body; trailing buttons at natural width |
| Settings | "Preferences": AdwPreferencesDialog with 4 pages (Recording, Transcription, Library, Browser companion). Saved voices pushed as a subpage. | "Settings": Settings scene TabView with the same 4 tabs. Saved voices pushed in a NavigationStack. |
| Recording with the app hidden | GNotification updated each second: "Recording, 00:12:48" / "{title}. Your microphone and the meeting in your browser." with Stop (destructive) and Open Cassini. A status icon where the desktop shows them. | MenuBarExtra showing a dot and "12:48". Menu: "Recording, 00:12:48", title, two level rows, "Stop Recording ⌥⌘R", "Add a Note…", "Open Cassini", "Your Mac will not sleep while Cassini records." |
| RecordFirst captions | "Your desktop may ask you to allow this next." / "Nothing to allow on this computer." | "macOS asks you to allow this next." / "macOS asks once more, for Screen & System Audio Recording." |
| others-permission line | absent | present |
| Shortcut glyphs | Ctrl+R, Ctrl+Alt+R | ⌘R, ⌥⌘R |
| Body / small text size | 15 / 13 px | 13 / 11.5 px |
| Fonts | system UI font | system UI font |
| Accent, red, amber on tint | `#1c71d8`, `#c01c28`, `#7a4d00` on `#fcefc9` | `#0063d1`, `#d70015`, `#7a4d00` on `#fff0c7` |
| Sidebar background | `#ebebed` | `#f1f0f5` |
| Radius: row / card / dialog / window | 10 / 12 / 14 / 14 | 7 / 10 / 12 / 10 |
| Speaker colours 1, 2, 3 | `#1c71d8`, `#b34700`, `#813d9c` | `#0063d1`, `#b34700`, `#7d3c98` |

- Use the system accent, destructive and warning colours where the platform has them, so the person's accent setting
  still applies. The hex values above are what screenshots run with.
- Speaker colours are assigned by order of first speaking.
- Saved-voice avatar tints cycle through: `#e1ebf8/#1a4f99`, `#e3f2ef/#0b5a54`, `#fcefe3/#8a3b07`, `#efeafb/#5b2bb5`.
- The no-sleep tooltip on the Recording page pill is "Your computer will not sleep while Cassini records." on both
  platforms (as drawn). The Mac menu-bar line says "Your Mac…" (as drawn).

## 11. Not drawn yet: do not invent, ask

The coordinator drafts copy for the items below in `ux-draft/strings.json`, and Silvio approves it. Until a string
exists, leave the surface out of the UI, or keep the existing behaviour unchanged.

Not drawn:
- Settings tabs Recording, Library and Browser companion.
- Summary placement.
- Menus: GNOME primary menu, Mac menu bar, Meeting "More actions".
- Notes in the Meeting view.
- Capture-path variants of "Listening inside your browser".
- Two-speaker labels when "Tell speakers apart" is off.
- Companion-setup states other than the drawn one.
- Empty search results.
- Extension popup copy.
- Info.plist and portal permission reasons.

## 12. Models and the network (DECISIONS-UX D4)

- Models are downloaded only from https://dist.gocassini.com, using its manifest, by `(id, source_sha256)`.
  Verification and install rules are in D4 and are identical on both apps.
- Downloads happen only when the person asks. Each file is checked against both sha256 values before it is used.
- The only other network use is checking for updates, which sends no meeting data.
- Whistle is bundled in both apps with identical pinned weights and engine (D5). Every process that loads the
  engine sets `NEEDLE_TELEMETRY=0` and `DO_NOT_TRACK=1` (and `ORT_DISABLE_TELEMETRY=1` for ONNX Runtime). The same
  audio must produce identical words in both apps.
- Size copy is computed from the manifest; it is never typed by hand.

