# Shared string source

D14 Search date-filter and D95 unknown-date group copy are vendored from `codemyriad/cassini-ux` at `484c6048447381e04fd1d1133e7ae02c6c6d5e58`,
`strings/strings.json` (SHA-256 `2b672fc8a88e62d704e6e2b5a4ed8d999a8aa77e90b8c006e7c7c0e43d26e169`).
Entries: `search.filter.anyDate`, `search.filter.date.today`, `search.filter.date.week`,
`search.filter.date.month`, `library.group.unknownDate`. Today reuses the existing Library translation; all values match the shared catalog.
No shared catalog or contract was edited.

`Library.xcstrings` uses the English source key `Date unknown` for the shared
`library.group.unknownDate` entry. Its six values are byte-identical to that source entry:
English `Date unknown`, Italian `Data sconosciuta`, French `Date inconnue`, Spanish `Fecha desconocida`,
Brazilian Portuguese and European Portuguese `Data desconhecida`. The source entry is a plain heading,
without count placeholders or plural transformations.

D96 bulk transfer copy is pinned to cassini-ux `4d577376f6360ed352fa75307f4dc47890ed9858`,
`strings/strings.json` (SHA-256 `7b059577a6e4a5d692ccb5c745916bc790e9e0fe7c77c5572fb64fda80f0f7b3`).
`BulkTransfer.xcstrings` vendors `import.*`, `export.zip.*`, `common.cancel` and `common.done`, with all six locales
and the catalog plural forms. Placeholder names map to positional integer format arguments. D14 values above remain
unchanged; no shared source was edited.

The Whistle fallback notice (#117) is vendored from cassini-ux `7cdb069fb0b71953feeeb7a6805c63835f968540`,
`strings/strings.json` (SHA-256 `8b20048485bd928d2067806284c381ffb8033768ecf084387600517d0006690f`): entry
`models.parakeetUltra.noteFallback`, in `Notices.xcstrings` with all six locales, every value as in the catalog.
The entries above stay at their pins; no shared source was edited.
