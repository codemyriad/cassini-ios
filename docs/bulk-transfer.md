# Several notes at once (D96)

The existing multi-file import picker also accepts ZIP. Importing an archive uses the same digest-deduplicating
importer as individual audio/Cassini files. A completed member stays in the Library if the transfer is
cancelled. The summary omits zero counts and reports imported, duplicate, unsupported and failed files. Directories count toward
archive safety limits but never toward unsupported-file counters. Whole-archive failures have one specific message,
without also counting a failed file; repeated identical messages are deduplicated. Storage-full errors use the existing
localized storage notice, and a new nonempty batch clears the preceding import error. Nested
archives, empty directories, symlinks and Finder metadata (`__MACOSX` / `._` sidecars) are ignored; they are never
opened as notes or followed as paths. A directory carrying expanded data refuses the whole archive as damaged. Directory identity is preserved across raw/Unicode path aliases, Windows separators, DOS attributes and Unix attributes. Even an empty directory requires zero CRC, a readable matching local header, and stored or deflated encoding; deflated directories must prove their streams are empty and complete.

Library's native Edit control selects notes. Export All as ZIP includes every finished Library note, independently
of search/Starred filters; Export Selected as ZIP appears only for a nonempty selection. The save/share sheet
offers a completed archive, containing one file per selected note and no extra manifest. Existing portable
export handles Cassini documents/versions/provenance. Clean imported documents remain byte-identical, even with
a missing/stale optional TITLE tag, so importing the ZIP detects the original digest. The stored audio/document
and note.json are never written by bulk export. Actual local transcript/title/speaker edits require a private
portable snapshot for a verified document because iOS stores those edits beside the source; that snapshot includes
those edits without replacing the source. Audio-only notes keep their original bytes and extension. Every non-OK
Cassini document keeps its original bytes even when the note has local words, edits or renamed speakers: those
changes cannot authenticate the original audio binding or recording start. Its on-device versions remain in the
Library. Wordless Cassini documents also keep their original bytes. Export names use the existing naming rule, with case-insensitive numeric
collision suffixes. A missing/deleted/live-recording member fails the export atomically rather than being
silently omitted. Single-note export formats remain unchanged.

Recovered interrupted captures without usable audio and active recordings are excluded from all/selected export
and selection controls. A Library containing only a live recording offers no Edit/ZIP action. Trashing a selected note immediately prunes the selection. Share-sheet cleanup
runs on a worker with an awaitable completion fence, so removing a large archive never blocks the main actor.
Before preparing each member, export awaits recording finalization and re-reads the live note and audio URLs,
so a stopped recording that rotates from capture.caf to audio.m4a uses the completed file. Cancelling export
ends that wait immediately and leaves recording compression running. If the current transcription has no speech,
export seals the last local version with words; when only imported variants remain it keeps the original document bytes.

Archive bounds follow cassini-ux main `4d577376f6360ed352fa75307f4dc47890ed9858`, D96:

- 2,000 directory entries, including ignored members; 20 GB (20,000,000,000) expanded bytes; maximum 100:1 compression ratio.
- Every directory and local header is checked before importing any member: encrypted, absolute/parent/Windows
  traversal paths and inconsistent/truncated directory records reject the whole archive. An unreadable local signature or bad payload CRC can count as one failed member; local/central identity disagreements and malformed local extras refuse the whole archive.
- The existing 4 GiB single-file import limit also applies to members. An oversized member is counted as failed.
- Stored and deflated payloads stream in 64 KiB chunks, with CRC, exact size and actual-byte budget checks.
  A false expanded size stops publication of extra bytes, while validation keeps draining so actual size/ratio
  violations are refused as too large. The final ratio uses compressed bytes actually consumed on completion **or corruption/truncation**,
  excluding padding the inflater never consumed. A malformed tail cannot downgrade an over-ratio stream to an individual failed member. Before any note is imported, every deflated member (including ignored/oversized entries)
  streams to a discard consumer to enforce actual archive-wide limits; stored members account their payload size without reading it.
  This preflight writes no expanded data to disk. Central/local raw and decoded names, valid Unicode path annotations (including presence), and compression methods must agree before any import; a mismatch refuses the archive as damaged, even in an ignored member. Local extras are scanned once: AES and unsafe Unicode paths take priority over duplicate/truncated subblocks. Corrupt individual payloads still allow valid siblings to import.
  No archive path is passed to a filesystem write.
- All six classic EOCD ZIP64 sentinels and harmless local/directory descriptor/encoding/option flag differences are accepted; encryption (including AES method99/extra0x9901) and path checks still apply independently to both headers. Relative
  Windows separators normalize to `/`, valid POSIX colon names are accepted, and absolute/drive/parent paths are refused. Stored ZIP64 output supports the full archive size limit. Payloads and the directory are each written once.
  Partial exports and per-import UUID staging folders are removed on cancellation/failure; exports are also swept
  on next launch. Pending model-consent navigation waits until the import finishes so progress remains cancellable.

ZIP member names with the UTF-8 flag require valid UTF-8. Without that flag, iOS tries strict UTF-8 first,
then CP437 when UTF-8 decoding fails, matching Android #193. An unflagged sequence valid in both encodings is
interpreted as UTF-8. Valid Unicode-path annotations still apply; raw/decoded local/central identity and annotation
presence checks remain strict. Unmodified synthetic-text fixtures from macOS ditto and official 7-Zip 26.06 for
macOS verify filename and payload preservation, including unflagged UTF-8 from ditto. Tool versions, commands,
hashes and header facts are recorded in [the fixture receipts](../Tests/CassiniCoreTests/Resources/zip/REAL-WRITERS.md).
These are CLI writer captures, not Finder GUI, Windows Explorer, Windows 7-Zip or Android Files evidence.

All archive I/O runs on worker queues, with cancellation checked per chunk; main-actor code only presents
progress, summary and selection. Temporary import folders are below the existing launch-swept Exports root.
Exported file URLs are published only after the ZIP directory is written and synchronized, and discarded when
sharing closes. ZIP container timestamps never supply a meeting time. Export writes a note into the archive and
deletes its snapshot before preparing the next. Portable sealing deletes each preceding version intermediate
once its successor is complete. Scratch space is one growing ZIP plus the current note's bounded intermediates,
not a staged Library or all its versions. Unlike Android's document-provider destination, the iOS system share
sheet requires a completed local ZIP URL.

The portable format follows [PKWARE APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT),
stored/ZIP64 records and raw [zlib inflate](https://www.zlib.net/manual.html). No new runtime dependency is
required.

Platform differences: iOS uses its existing native document picker and system share/save sheet. The picker has
no custom filter-title API; shared `import.filter.cassiniAndZip` is the import button's accessibility hint.
Supported member audio types follow AVFoundation, so Android-only AMR/WebM containers are not promised. D96
copy, including all six translations/plurals, is pinned in [shared-strings-pin.md](shared-strings-pin.md). The
reviewed Android #166 rules for byte-preserving clean imports, Finder metadata, ZIP64 and header flags are
covered by regression tests here.

## Cross-platform review audit (main after #115/#119/#121)

| Defect class | Finding and regression |
| --- | --- |
| Directory payload / ignored bomb | Fixed directory payloads being silently ignored. `BulkTransferTests.directoryPayloadsAndMethodMismatchesRefuseBeforePublishingAnyNote` checks ordinary, Unix-attribute and forged-empty deflated directories after Good.wav. Normal ignored runtime bombs already refused; fixed corrupt-tail padded bombs being downgraded to corrupt members. `corruptDeflateTailsCannotHidePaddedRatioBombs` covers supported, ignored and AppleDouble members alone and after Good.wav; `malformedDirectoryRepresentationsRefuseBeforeAnyImport` covers DOS/Unicode aliases, bad CRC/method/local header and padded empty deflate. Valid empty DOS directories remain ignored. |
| Visibility before runtime validation | Already preflights every deflated entry to discard before calling the ordinary importer; no rollback of published notes. Bomb regressions observe no publication callbacks. `lateArchiveRefusalNeverPublishesOrRollsBackAnIndependentEditableImport` proves no importer call and retains the independent note's edited metadata byte-for-byte. |
| Central/local method mismatch | Fixed being downgraded to an individual failed entry. `localHeaderDisagreementsRefuseBeforeAnyPublication` covers name/Unicode/directory/Finder disagreement; `localExtraSecurityRefusalsPrecedeStructuralErrors` covers refusal priority. The directory-payload regression includes both method directions and an ignored README member, after Good.wav, and observes zero importer calls. |
| Ratio at completion | Uses whole declared compressed size as a conservative streaming denominator, then actual consumed bytes at success **or a corrupt/truncated exit** (fixed after review). `ZIPAgyReviewTests.mixedCompressibilityIsJudgedByTheCompleteStreamNotItsHighlyCompressiblePrefix` independently verifies a prefix above 100:1, accepts the complete valid mixed stream and compares every byte; `prematureEOFStillChecksConsumedRatioBeforeReportingCorruption` exercises EOF after expanded output; `runtimeRatioUsesActualOutputAndActualCompressedInputBeforePadding` still refuses forged/padded bombs. |
| Single import alongside ZIP | Already uses atomic `NoteStore.insert(_:unlessLiveSourceIs:)`, with no bulk rollback. `singleAndBulkImportsRacingPastDigestLookupCreateOnlyOneNote` gates both after early digest lookup and uses a multiwaiter continuation latch, checks exactly one new note plus one duplicate and verifies the loser staging folder is absent on disk; the late-refusal regression retains the independent edited note. |
| Queued/failed transcript export | Already serializes stored words independently of the pending/failed transcription status. `ExportServiceTests.archiveKeepsStoredTranscriptWhileAnotherTranscriptionIsQueuedOrFailed` extracts the ZIP and verifies the complete Cassini transcript for both states. |

These are local regressions; no shared vectors, strings or contract files are changed.
