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
