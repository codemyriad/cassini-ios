# Shared string source

D14 Search date-filter copy is vendored from `codemyriad/cassini-ux` at `4d577376f6360ed352fa75307f4dc47890ed9858`,
`strings/strings.json` (SHA-256 `7b059577a6e4a5d692ccb5c745916bc790e9e0fe7c77c5572fb64fda80f0f7b3`).
Entries: `search.filter.anyDate`, `search.filter.date.today`, `search.filter.date.week`,
`search.filter.date.month`. Today reuses the existing Library translation; all values match the shared catalog.
No shared catalog or contract was edited.

D96 batch import/ZIP export copy is in `Bulk.xcstrings`, using the canonical IDs: `import.filter.cassiniAndZip`,
`import.progress`, `import.cancelled`, the four `import.summary.*` parts, the five `import.zip.failed.*` errors,
`export.zip.all`, `export.zip.selected`, `export.zip.progress`, `export.zip.done`, and `common.cancel`.
All six shared languages are copied verbatim. Count placeholders `{n}` become native `%lld` plural substitutions;
progress placeholders stay named and are replaced with locale-formatted numbers. Only nonzero summary parts appear.
