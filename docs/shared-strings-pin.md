# Shared string source

D14 Search date-filter copy is vendored from `codemyriad/cassini-ux` at `4d577376f6360ed352fa75307f4dc47890ed9858`,
`strings/strings.json` (SHA-256 `7b059577a6e4a5d692ccb5c745916bc790e9e0fe7c77c5572fb64fda80f0f7b3`).
Entries: `search.filter.anyDate`, `search.filter.date.today`, `search.filter.date.week`,
`search.filter.date.month`. Today reuses the existing Library translation; all values match the shared catalog.
No shared catalog or contract was edited.

D96 bulk transfer copy is pinned to cassini-ux `4d577376f6360ed352fa75307f4dc47890ed9858`,
`strings/strings.json` (SHA-256 `7b059577a6e4a5d692ccb5c745916bc790e9e0fe7c77c5572fb64fda80f0f7b3`).
`BulkTransfer.xcstrings` vendors `import.*`, `export.zip.*`, `common.cancel` and `common.done`, with all six locales
and the catalog plural forms. Placeholder names map to positional integer format arguments. D14 values above remain
unchanged; no shared source was edited.

The Whistle fallback notice (#117) is vendored from cassini-ux `7cdb069fb0b71953feeeb7a6805c63835f968540`,
`strings/strings.json` (SHA-256 `8b20048485bd928d2067806284c381ffb8033768ecf084387600517d0006690f`): entry
`models.parakeetUltra.noteFallback`, in `Notices.xcstrings` with all six locales, every value as in the catalog.
The entries above stay at their pins; no shared source was edited.
