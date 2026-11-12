# Format vectors

How Cassini writes times, durations, sizes, day groups and row lines (HARMONY section 6). `format-vectors.json` gives inputs and the exact expected text, with a fixed clock (27 October 2026, 14:18, Europe/Rome) and fixed en-GB patterns. Run by GNOME and Mac as unit tests, all cases; iOS runs the size rule. Vendor the file at a pinned commit of this repo and check its SHA-256; a case is only added or changed here.

W0.4/v5 changes positive ETA badge labels to the compact L-26 wording. The zero-minute current sentence remains provisional pending Alex. Other format rules are unchanged.
