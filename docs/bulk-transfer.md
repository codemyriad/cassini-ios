# Several notes at once (D96)

The existing multi-file import picker also accepts ZIP. Importing an archive uses the same digest-deduplicating
importer as individual audio/Cassini files. A completed member stays in the Library if the transfer is cancelled.
The summary omits zero counts and reports imported, duplicate, unsupported and failed files. Nested archives,
directories and symlinks are ignored; they are never opened as files or followed as paths.

Library's native Edit control selects notes. Export All as ZIP includes every live Library note, independently of
search/Starred filters; Export Selected as ZIP appears only for a nonempty selection. The save/share sheet offers a
completed archive, containing one file per selected note and no extra manifest. Existing portable export handles
Cassini documents/versions/provenance. Audio-only notes keep their original bytes and extension; unknown/unreadable
Cassini documents keep their original bytes. Export names use the existing naming rule, with case-insensitive
numeric collision suffixes. A missing/deleted/live-recording member fails the export atomically rather than being
silently omitted. Single-note export remains unchanged.

Archive bounds follow cassini-ux main `4d577376f6360ed352fa75307f4dc47890ed9858`, D96:

- 2,000 directory entries, including ignored members; 20 GB (20,000,000,000) expanded bytes; maximum 100:1 compression ratio.
- Every directory and local header is checked before importing any member: encrypted, absolute/parent/Windows
  traversal paths and inconsistent/truncated directory records reject the whole archive. A damaged member header or CRC counts as one failed member; other valid members continue.
- The existing 4 GiB single-file import limit also applies to members. An oversized member is counted as failed.
- Stored and deflated payloads stream in 64 KiB chunks, with CRC, exact size and actual-byte budget checks.
  Ignored/oversized members are not expanded. No archive path is passed to a filesystem write.
- Stored ZIP64 output supports the full archive size limit. Payloads and the directory are each written once.
  Partial exports and per-import UUID staging folders are removed on cancellation/failure; exports are also swept
  on next launch. Pending model-consent navigation waits until the import finishes so progress remains cancellable.

All archive I/O runs on worker queues, with cancellation checked per chunk; main-actor code only presents progress,
summary and selection. Temporary import folders are below the existing launch-swept Exports root. Exported file
URLs are published only after the ZIP directory is written and synchronized, and discarded when sharing closes.
ZIP container timestamps never supply a meeting time.

The portable format follows [PKWARE APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT), stored/ZIP64
records and raw [zlib inflate](https://www.zlib.net/manual.html). No new runtime dependency is required.

Platform differences: iOS uses its existing native document picker and system share/save sheet. The picker has no
custom filter-title API; shared `import.filter.cassiniAndZip` is the import button's accessibility hint. Supported
member audio types follow AVFoundation, so Android-only AMR/WebM containers are not promised. D96 copy, including
all six translations/plurals, is pinned in [shared-strings-pin.md](shared-strings-pin.md). The inspected Android #166
head still used earlier archive constants; this implementation follows the coordinator's newer shared D96 limits.
