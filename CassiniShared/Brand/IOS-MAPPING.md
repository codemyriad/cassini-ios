# iOS token usage

Pinned source: cassini-ux b4dec4160a04a5e9995ce0a74d0215aa24a3da9c, version2026-11-12.3.
All53 token roles and the separate decided derived `card-rest` are generated and tested in both appearances.

The desktop roles `sidebar`, `sidebar-mac`, `field` and `field-line` are unused on iOS/iPadOS. They remain in the generated table and sync test by name; iOS retains its native navigation chrome. No wildcard exemption applies.

Resting meeting cards use `card-rest`. Neutral pills and secondary controls use `ink` at10% over their actual background, rather than `neutral-tint`. Error washes use `error-tint`, which matches the Record wash. Speaker names and avatars read the stored meeting slot; naming reveals that slot. Saved voices read their immutable save sequence. No token remains provisional.
