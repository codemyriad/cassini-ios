# Portable format pin

D95 uses codemyriad/cassini-format commit `32f37a6200c88bdd4d23c1f44497f1761f3401da` (format #8).
CI checks out this exact revision. Local gates must set `CASSINI_CONFORMANCE` to its `spec/conformance` directory.

Reader regressions load vectors 027, 028 and 029: authoritative UTC start, a DATE pack stamp that must fall through to the local label, and a genuine offset-bearing DATE. File creation time remains a sorting fallback; it is never displayed as the meeting start. Imported local labels are displayed verbatim without assigning a zone. Date-range filters use the viewer-local day of an instant or the written day of a local label, without assigning that label a zone.

Live capture stores position-zero time after microphone permission/session preparation. Export writes `recordedAtUtc`, its mirror and DATE from that start; imported files retain their original start metadata. Catalogue loading reads portable headers without hashing audio or rewriting user files. Rebuilding a missing catalogue reads portable metadata rather than treating filesystem creation as recording start.

Markdown consumes `Note.meetingTime`: it formats known instants, preserves zone-less labels, and omits unknown dates. It never substitutes a seal, import or catalogue timestamp. Pure and production-adapter tests cover all three states.
