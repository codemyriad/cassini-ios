#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Validate contract/import-types.json (W0.7 / L-25 shared audio import types).

usage: python3 -I contract/validate_import_types.py [import-types.json]
       python3 -I contract/validate_import_types.py --self-test

Exit 0 when the file is clean; print one line per problem otherwise. Standard library only.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
SCHEMA = "cassini-ux/import-types@1"
PLATFORMS = ["gnome", "mac", "ios", "android"]
STATUSES = {"decided", "open"}
TOP_KEYS = {"schema", "version", "source", "platforms", "rule", "types"}
SOURCE_KEYS = {"canvas", "package", "decisions", "phase2"}
ENTRY_KEYS = {
    "id",
    "label",
    "status",
    "decisions",
    "open",
    "extensions",
    "mimeTypes",
    "compatibilityMimeTypes",
    "utis",
    "androidMimeTypes",
    "contentValidation",
    "headerValidation",
    "note",
}
CONTENT_VALIDATION_KEYS = {
    "ambiguousExtensions",
    "minProbeBytes",
    "containerMagicHex",
    "acceptedBosMagicHex",
    "secondPageMagicHex",
    "rejectedBosMagicHex",
    "rejectedExtensions",
    "rejectedMimePrefixes",
    "rule",
}
HEADER_VALIDATION_KEYS = {
    "minProbeBytes",
    "magicHex",
    "firstMetadataBlockType",
    "streamInfoLength",
    "rejectedMimeTypes",
    "rule",
}
# Native FLAC (RFC 9639): "fLaC" + 4-byte metadata block header + 34-byte STREAMINFO.
FLAC_MAGIC_HEX = "664c6143"
FLAC_STREAMINFO_BLOCK_TYPE = 0
FLAC_STREAMINFO_LENGTH = 34
FLAC_MIN_PROBE_BYTES = 4 + 4 + FLAC_STREAMINFO_LENGTH
OGG_FLAC_MIMES = ("audio/x-flac+ogg", "audio/x-oggflac")

VERSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\.\d+$")
ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
DECISION_RE = re.compile(r"^L-\d{2}$")
ENTRY_DECISION_RE = re.compile(r"^(?:L-\d{2}|D-\d+)$")
OPEN_ID_RE = re.compile(r"^(?:L-\d{2}|D-\d+|C\d+)$")
EXT_RE = re.compile(r"^\.[a-z0-9]+$")
PICKER_MIME_RE = re.compile(r"^audio/[a-z0-9][a-z0-9.+_-]*$")
COMPAT_MIME_RE = re.compile(r"^(?:audio/[a-z0-9][a-z0-9.+_-]*|application/ogg)$")
MIME_PREFIX_RE = re.compile(r"^[a-z0-9-]+/$")
HEX_BYTES_RE = re.compile(r"^[0-9a-f]{2}(?:[0-9a-f]{2})*$")
UTI_RE = re.compile(r"^[a-z0-9]+(?:\.[a-z0-9-]+)+$")

DISALLOWED_BROAD_PICKER_MIMES = {
    "application/ogg",
    "application/x-ogg",
    "audio/ogg",
    "audio/x-ogg",
}

DISALLOWED_ANDROID_PICKER_MIMES = {
    "application/ogg",
    "application/x-ogg",
}

DISALLOWED_BROAD_UTIS = {
    "public.item",
    "public.data",
    "public.content",
    "public.audiovisual-content",
    "public.audio",
    "public.movie",
    "public.video",
    "org.xiph.ogg-video",
}

# Canonical freedesktop shared-mime-info alias and sub-class-of relationships
# used by GIO / GtkFileFilter (gtk_file_filter_add_mime_type -> g_content_type_is_a).
XDG_MIME_ALIASES: dict[str, str] = {
    "application/x-ogg": "application/ogg",
    "audio/x-ogg": "audio/ogg",
    "video/x-ogg": "video/ogg",
    "audio/mp3": "audio/mpeg",
    "audio/x-mp3": "audio/mpeg",
    "audio/x-mpg": "audio/mpeg",
    "audio/m4a": "audio/mp4",
    "audio/x-m4a": "audio/mp4",
    "audio/wav": "audio/vnd.wave",
    "audio/x-wav": "audio/vnd.wave",
    "audio/x-flac": "audio/flac",
    "audio/x-oggflac": "audio/x-flac+ogg",
    "audio/vorbis": "audio/x-vorbis+ogg",
    "audio/x-vorbis": "audio/x-vorbis+ogg",
    "audio/speex": "audio/x-speex+ogg",
    "audio/x-speex": "audio/x-speex+ogg",
}

XDG_MIME_PARENTS: dict[str, tuple[str, ...]] = {
    "audio/ogg": ("application/ogg",),
    "video/ogg": ("application/ogg",),
    "video/x-theora+ogg": ("video/ogg",),
    "video/x-ogm+ogg": ("video/ogg",),
    "audio/x-opus+ogg": ("audio/ogg",),
    "audio/x-flac+ogg": ("audio/ogg",),
    "audio/x-vorbis+ogg": ("audio/ogg",),
    "audio/x-speex+ogg": ("audio/ogg",),
    "audio/x-m4b": ("audio/mp4",),
}

UNSUPPORTED_OGG_SUBTYPES = {
    "video/ogg",
    "video/x-theora+ogg",
    "video/x-ogm+ogg",
    "audio/x-vorbis+ogg",
    "audio/vorbis",
    "audio/x-vorbis",
    "audio/x-speex+ogg",
    "audio/speex",
    "audio/x-speex",
    "audio/x-flac+ogg",
    "audio/x-oggflac",
}

KNOWN_XDG_MIMES = (
    set(XDG_MIME_ALIASES)
    | set(XDG_MIME_ALIASES.values())
    | set(XDG_MIME_PARENTS)
    | {parent for parents in XDG_MIME_PARENTS.values() for parent in parents}
    | {
        "audio/opus",
        "audio/mp4a-latm",
        "video/mp4",
        "video/mpeg",
    }
)

EXPECTED_DECIDED = [
    ("opus-ogg", "Opus/Ogg", [".opus", ".ogg"]),
    ("mp3", "MP3", [".mp3"]),
    ("m4a", "M4A/AAC", [".m4a"]),
    ("wav", "WAV", [".wav"]),
    ("flac", "FLAC", [".flac"]),
]
EXPECTED_OPEN: list[tuple[str, str, list[str], list[str]]] = []
# Decided entries that must cite a decision beyond L-25.
EXPECTED_EXTRA_DECISIONS = {"flac": "D-938"}
# Decided entries with a fixed native container that must carry headerValidation.
EXPECTED_HEADER_VALIDATION = {"flac"}


def canonical_xdg_mime(mime: str) -> str:
    return XDG_MIME_ALIASES.get(mime, mime)


def mime_is_subclass_of(child: str, parent: str) -> bool:
    """Return True when XDG shared-mime-info / GIO treats child as a subclass of parent."""
    target = canonical_xdg_mime(parent)
    stack = [canonical_xdg_mime(child)]
    visited: set[str] = set()
    while stack:
        cur = stack.pop()
        if cur == target:
            return True
        if cur in visited:
            continue
        visited.add(cur)
        stack.extend(XDG_MIME_PARENTS.get(cur, ()))
    return False


def _strict_object_pairs(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"duplicate JSON key {key!r}")
        obj[key] = value
    return obj


def _reject_constants(const: str):
    raise ValueError(f"non-standard JSON constant {const!r}")


def load_strict_json(path: Path):
    text = path.read_text(encoding="utf-8")
    return json.loads(text, object_pairs_hook=_strict_object_pairs, parse_constant=_reject_constants)


def _check_string_list(
    where: str,
    value,
    item_name: str,
    pattern: re.Pattern[str],
    problems: list[str],
    *,
    allow_empty: bool = False,
) -> list[str]:
    if not isinstance(value, list) or (not allow_empty and not value):
        qualifier = "a list" if allow_empty else "a non-empty list"
        problems.append(f"{where}: {item_name} must be {qualifier}")
        return []
    seen: set[str] = set()
    valid: list[str] = []
    for item in value:
        if not isinstance(item, str) or not pattern.match(item):
            problems.append(f"{where}: invalid {item_name} item {item!r} (expected {pattern.pattern})")
            continue
        if item in seen:
            problems.append(f"{where}: duplicate {item_name} item {item!r}")
            continue
        seen.add(item)
        valid.append(item)
    return valid


def _check_content_validation(where: str, cv, entry_exts: list[str], problems: list[str]) -> None:
    if not isinstance(cv, dict):
        problems.append(f"{where}: contentValidation must be an object")
        return

    unknown = set(cv) - CONTENT_VALIDATION_KEYS
    missing = CONTENT_VALIDATION_KEYS - set(cv)
    if unknown:
        problems.append(f"{where}.contentValidation: unknown keys {sorted(unknown)}")
    if missing:
        problems.append(f"{where}.contentValidation: missing keys {sorted(missing)}")

    amb_exts = _check_string_list(
        f"{where}.contentValidation",
        cv.get("ambiguousExtensions"),
        "ambiguousExtensions",
        EXT_RE,
        problems,
    )
    ext_set = set(entry_exts)
    for ext in amb_exts:
        if ext_set and ext not in ext_set:
            problems.append(
                f"{where}.contentValidation: ambiguousExtensions item {ext!r} must appear in extensions"
            )

    min_probe = cv.get("minProbeBytes")
    if isinstance(min_probe, bool) or not isinstance(min_probe, int) or min_probe < 600:
        problems.append(f"{where}.contentValidation: minProbeBytes must be an integer >= 600")

    cmagic = cv.get("containerMagicHex")
    if not isinstance(cmagic, str) or not HEX_BYTES_RE.match(cmagic):
        problems.append(f"{where}.contentValidation: containerMagicHex must be lowercase hex bytes")

    second_magic = cv.get("secondPageMagicHex")
    if not isinstance(second_magic, str) or not HEX_BYTES_RE.match(second_magic):
        problems.append(f"{where}.contentValidation: secondPageMagicHex must be lowercase hex bytes")

    accepted_bos = _check_string_list(
        f"{where}.contentValidation",
        cv.get("acceptedBosMagicHex"),
        "acceptedBosMagicHex",
        HEX_BYTES_RE,
        problems,
    )
    rejected_bos = _check_string_list(
        f"{where}.contentValidation",
        cv.get("rejectedBosMagicHex"),
        "rejectedBosMagicHex",
        HEX_BYTES_RE,
        problems,
    )
    overlap_bos = set(accepted_bos) & set(rejected_bos)
    if overlap_bos:
        problems.append(
            f"{where}.contentValidation: acceptedBosMagicHex and rejectedBosMagicHex overlap on {sorted(overlap_bos)}"
        )

    rej_exts = _check_string_list(
        f"{where}.contentValidation",
        cv.get("rejectedExtensions"),
        "rejectedExtensions",
        EXT_RE,
        problems,
    )
    overlap_ext = set(rej_exts) & ext_set
    if overlap_ext:
        problems.append(
            f"{where}.contentValidation: rejectedExtensions overlaps entry extensions on {sorted(overlap_ext)}"
        )

    rej_prefixes = _check_string_list(
        f"{where}.contentValidation",
        cv.get("rejectedMimePrefixes"),
        "rejectedMimePrefixes",
        MIME_PREFIX_RE,
        problems,
    )
    if "video/" not in rej_prefixes:
        problems.append(f"{where}.contentValidation: rejectedMimePrefixes must include 'video/'")

    rule = cv.get("rule")
    if not isinstance(rule, str) or not rule.strip():
        problems.append(f"{where}.contentValidation: rule must be a non-empty string")


def _check_header_validation(where: str, hv, entry: dict, problems: list[str]) -> None:
    if not isinstance(hv, dict):
        problems.append(f"{where}: headerValidation must be an object")
        return
    unknown = set(hv) - HEADER_VALIDATION_KEYS
    missing = HEADER_VALIDATION_KEYS - set(hv)
    if unknown:
        problems.append(f"{where}.headerValidation: unknown keys {sorted(unknown)}")
    if missing:
        problems.append(f"{where}.headerValidation: missing keys {sorted(missing)}")

    if "contentValidation" in entry:
        problems.append(f"{where}: headerValidation and contentValidation are mutually exclusive")
    if entry.get("compatibilityMimeTypes"):
        problems.append(f"{where}: headerValidation entries must not declare compatibilityMimeTypes")

    if hv.get("magicHex") != FLAC_MAGIC_HEX:
        problems.append(f"{where}.headerValidation: magicHex must be {FLAC_MAGIC_HEX!r} (native fLaC)")
    block_type = hv.get("firstMetadataBlockType")
    if isinstance(block_type, bool) or block_type != FLAC_STREAMINFO_BLOCK_TYPE:
        problems.append(
            f"{where}.headerValidation: firstMetadataBlockType must be {FLAC_STREAMINFO_BLOCK_TYPE} (STREAMINFO)"
        )
    length = hv.get("streamInfoLength")
    if isinstance(length, bool) or length != FLAC_STREAMINFO_LENGTH:
        problems.append(f"{where}.headerValidation: streamInfoLength must be {FLAC_STREAMINFO_LENGTH}")
    min_probe = hv.get("minProbeBytes")
    if isinstance(min_probe, bool) or not isinstance(min_probe, int) or min_probe < FLAC_MIN_PROBE_BYTES:
        problems.append(f"{where}.headerValidation: minProbeBytes must be an integer >= {FLAC_MIN_PROBE_BYTES}")

    rejected = _check_string_list(
        f"{where}.headerValidation",
        hv.get("rejectedMimeTypes"),
        "rejectedMimeTypes",
        COMPAT_MIME_RE,
        problems,
    )
    accepted = set(entry.get("mimeTypes") or []) | set(entry.get("androidMimeTypes") or [])
    overlap = accepted & set(rejected)
    if overlap:
        problems.append(f"{where}.headerValidation: rejectedMimeTypes overlaps accepted MIME types on {sorted(overlap)}")
    for ogg_flac in OGG_FLAC_MIMES:
        if ogg_flac not in rejected:
            problems.append(f"{where}.headerValidation: rejectedMimeTypes must include {ogg_flac!r}")
        if ogg_flac in accepted:
            problems.append(f"{where}: Ogg-encapsulated FLAC MIME {ogg_flac!r} must not be accepted for native FLAC")

    rule = hv.get("rule")
    if not isinstance(rule, str) or not rule.strip():
        problems.append(f"{where}.headerValidation: rule must be a non-empty string")


def check_shape(data) -> list[str]:
    problems: list[str] = []
    if not isinstance(data, dict):
        return ["the file is not a JSON object"]

    unknown_top = set(data) - TOP_KEYS
    missing_top = TOP_KEYS - set(data)
    if unknown_top:
        problems.append(f"top-level: unknown keys {sorted(unknown_top)}")
    if missing_top:
        problems.append(f"top-level: missing keys {sorted(missing_top)}")

    if data.get("schema") != SCHEMA:
        problems.append(f"schema must be {SCHEMA!r}")
    if not isinstance(data.get("version"), str) or not VERSION_RE.match(data["version"]):
        problems.append("version must look like 2026-11-14.1")
    if data.get("platforms") != PLATFORMS:
        problems.append(f"platforms must be {PLATFORMS!r}")
    if not isinstance(data.get("rule"), str) or not data["rule"].strip():
        problems.append("rule must be a non-empty string")

    source = data.get("source")
    if not isinstance(source, dict):
        problems.append("source must be an object")
    else:
        unknown_src = set(source) - SOURCE_KEYS
        if unknown_src:
            problems.append(f"source: unknown keys {sorted(unknown_src)}")
        for key in ("canvas", "package", "phase2"):
            if not isinstance(source.get(key), str) or not source[key].strip():
                problems.append(f"source.{key} must be a non-empty string")
        _check_string_list("source", source.get("decisions"), "decisions", DECISION_RE, problems)

    entries = data.get("types")
    if not isinstance(entries, list) or not entries:
        return problems + ["types must be a non-empty list"]

    seen_ids: dict[str, int] = {}
    seen_labels: dict[str, str] = {}
    seen_exts: dict[str, str] = {}
    seen_mimes: dict[str, str] = {}
    seen_utis: dict[str, str] = {}

    for idx, entry in enumerate(entries):
        if not isinstance(entry, dict):
            problems.append(f"types[{idx}]: not an object")
            continue

        raw_id = entry.get("id")
        where = f"types[{raw_id}]" if isinstance(raw_id, str) and raw_id else f"types[{idx}]"

        unknown = set(entry) - ENTRY_KEYS
        if unknown:
            problems.append(f"{where}: unknown keys {sorted(unknown)}")

        if not isinstance(raw_id, str) or not ID_RE.match(raw_id):
            problems.append(f"{where}: id {raw_id!r} must match {ID_RE.pattern}")
        elif raw_id in seen_ids:
            problems.append(f"{where}: duplicate id {raw_id!r} (already at index {seen_ids[raw_id]})")
        else:
            seen_ids[raw_id] = idx

        label = entry.get("label")
        if not isinstance(label, str) or not label.strip():
            problems.append(f"{where}: label must be a non-empty string")
        elif label in seen_labels:
            problems.append(f"{where}: duplicate label {label!r} (already used by {seen_labels[label]!r})")
        else:
            seen_labels[label] = str(raw_id)

        note = entry.get("note")
        if not isinstance(note, str) or not note.strip():
            problems.append(f"{where}: note must be a non-empty string")

        status = entry.get("status")
        if status not in STATUSES:
            problems.append(f"{where}: status {status!r} not in {sorted(STATUSES)}")
        elif status == "decided":
            _check_string_list(where, entry.get("decisions"), "decisions", ENTRY_DECISION_RE, problems)
            if entry.get("open"):
                problems.append(f"{where}: decided entry cannot carry open ids {entry.get('open')!r}")
        elif status == "open":
            _check_string_list(where, entry.get("open"), "open", OPEN_ID_RE, problems)
            if entry.get("decisions"):
                problems.append(f"{where}: open entry cannot carry decisions {entry.get('decisions')!r}")

        exts = _check_string_list(where, entry.get("extensions"), "extensions", EXT_RE, problems)
        for ext in exts:
            owner = seen_exts.get(ext)
            if owner is not None:
                problems.append(f"{where}: duplicate extension {ext!r} across entries (already in {owner!r})")
            else:
                seen_exts[ext] = str(raw_id)

        mimes = _check_string_list(where, entry.get("mimeTypes"), "mimeTypes", PICKER_MIME_RE, problems)
        for mime in mimes:
            if mime in DISALLOWED_BROAD_PICKER_MIMES:
                problems.append(
                    f"{where}: MIME type {mime!r} is a broad container supertype and must live in compatibilityMimeTypes, not mimeTypes"
                )
            owner = seen_mimes.get(mime)
            if owner is not None:
                problems.append(f"{where}: duplicate MIME type {mime!r} across entries (already in {owner!r})")
            else:
                seen_mimes[mime] = str(raw_id)

        compat_mimes = _check_string_list(
            where,
            entry.get("compatibilityMimeTypes"),
            "compatibilityMimeTypes",
            COMPAT_MIME_RE,
            problems,
            allow_empty=True,
        )
        for cmime in compat_mimes:
            owner = seen_mimes.get(cmime)
            if owner is not None:
                problems.append(
                    f"{where}: compatibilityMimeTypes item {cmime!r} duplicates MIME already in {owner!r}"
                )
            else:
                seen_mimes[cmime] = str(raw_id)

        utis = _check_string_list(where, entry.get("utis"), "utis", UTI_RE, problems)
        for uti in utis:
            if uti in DISALLOWED_BROAD_UTIS:
                problems.append(f"{where}: UTI {uti!r} is too broad or video-scoped for a per-format audio import entry")
            owner = seen_utis.get(uti)
            if owner is not None:
                problems.append(f"{where}: duplicate UTI {uti!r} across entries (already in {owner!r})")
            else:
                seen_utis[uti] = str(raw_id)

        android_mimes = _check_string_list(
            where,
            entry.get("androidMimeTypes"),
            "androidMimeTypes",
            COMPAT_MIME_RE,
            problems,
        )
        allowed_android = set(mimes) | set(compat_mimes)
        for amime in android_mimes:
            if amime in DISALLOWED_ANDROID_PICKER_MIMES:
                problems.append(
                    f"{where}: androidMimeTypes item {amime!r} is too broad for Android SAF pickers"
                )
            if allowed_android and amime not in allowed_android:
                problems.append(
                    f"{where}: androidMimeTypes item {amime!r} must appear in mimeTypes or compatibilityMimeTypes"
                )

        has_cv = "contentValidation" in entry
        needs_cv = bool(compat_mimes) or (".ogg" in exts) or any(a in compat_mimes for a in android_mimes)
        if has_cv:
            _check_content_validation(where, entry.get("contentValidation"), exts, problems)
        elif status == "decided" and needs_cv:
            problems.append(
                f"{where}: decided entry with ambiguous container extension or compatibilityMimeTypes must specify contentValidation"
            )
        if "headerValidation" in entry:
            _check_header_validation(where, entry.get("headerValidation"), entry, problems)

    return problems


def check_mime_hierarchy(data) -> list[str]:
    """Ensure decided picker mimeTypes never admit video/*, open formats, or unsupported Ogg codecs via GIO subclasses."""
    if not isinstance(data, dict) or not isinstance(data.get("types"), list):
        return []
    entries = [e for e in data["types"] if isinstance(e, dict)]
    problems: list[str] = []

    open_mimes: list[tuple[str, str]] = []
    for entry in entries:
        if entry.get("status") == "open":
            eid = str(entry.get("id"))
            for m in entry.get("mimeTypes") or []:
                if isinstance(m, str):
                    open_mimes.append((eid, m))

    universe = set(KNOWN_XDG_MIMES)
    for entry in entries:
        for key in ("mimeTypes", "compatibilityMimeTypes", "androidMimeTypes"):
            for m in entry.get(key) or []:
                if isinstance(m, str):
                    universe.add(m)

    for entry in entries:
        if entry.get("status") != "decided":
            continue
        eid = str(entry.get("id"))
        where = f"types[{eid}]"
        for picker_mime in entry.get("mimeTypes") or []:
            if not isinstance(picker_mime, str):
                continue
            matched_subtypes = sorted(cand for cand in universe if mime_is_subclass_of(cand, picker_mime))
            for sub in matched_subtypes:
                if sub.startswith("video/"):
                    problems.append(
                        f"{where}: picker MIME {picker_mime!r} admits video subclass {sub!r} on GIO/GTK"
                    )
                for open_id, open_mime in open_mimes:
                    if mime_is_subclass_of(sub, open_mime) or mime_is_subclass_of(open_mime, sub):
                        problems.append(
                            f"{where}: picker MIME {picker_mime!r} admits open {open_id!r} subclass {sub!r} on GIO/GTK"
                        )
                if sub in UNSUPPORTED_OGG_SUBTYPES and not sub.startswith("video/"):
                    problems.append(
                        f"{where}: picker MIME {picker_mime!r} admits unsupported Ogg audio subclass {sub!r} on GIO/GTK"
                    )

    return problems


def check_policy(data) -> list[str]:
    """Verify the W0.7 / L-25 / D-938 canonical decided vs open format sets."""
    if not isinstance(data, dict) or not isinstance(data.get("types"), list):
        return []
    entries = [e for e in data["types"] if isinstance(e, dict)]
    problems: list[str] = []

    decided = [
        (e.get("id"), e.get("label"), e.get("extensions"))
        for e in entries
        if e.get("status") == "decided"
    ]
    if decided != EXPECTED_DECIDED:
        problems.append(
            f"policy: decided types must be {[x[0] for x in EXPECTED_DECIDED]} "
            f"with extensions {[x[2] for x in EXPECTED_DECIDED]}, got {decided!r}"
        )

    for e in entries:
        if e.get("status") == "decided" and "L-25" not in (e.get("decisions") or []):
            problems.append(f"types[{e.get('id')}]: decided L-25 import type must cite 'L-25' in decisions")
        extra = EXPECTED_EXTRA_DECISIONS.get(e.get("id"))
        if e.get("status") == "decided" and extra and extra not in (e.get("decisions") or []):
            problems.append(f"types[{e.get('id')}]: decided import type must cite {extra!r} in decisions")
        has_hv = "headerValidation" in e
        if e.get("id") in EXPECTED_HEADER_VALIDATION and e.get("status") == "decided" and not has_hv:
            problems.append(f"types[{e.get('id')}]: decided native-container type must specify headerValidation")
        if has_hv and e.get("id") not in EXPECTED_HEADER_VALIDATION:
            problems.append(f"types[{e.get('id')}]: headerValidation is only defined for {sorted(EXPECTED_HEADER_VALIDATION)}")

    decided_ext_owner = {
        ext: e.get("id")
        for e in entries
        if e.get("status") == "decided"
        for ext in (e.get("extensions") or [])
        if isinstance(ext, str)
    }
    for e in entries:
        cv = e.get("contentValidation")
        if not isinstance(cv, dict):
            continue
        for ext in cv.get("rejectedExtensions") or []:
            owner = decided_ext_owner.get(ext) if isinstance(ext, str) else None
            if owner is not None:
                problems.append(
                    f"types[{e.get('id')}].contentValidation: rejectedExtensions item {ext!r} is a decided import extension of {owner!r}"
                )

    opened = [
        (e.get("id"), e.get("label"), e.get("extensions"), e.get("open"))
        for e in entries
        if e.get("status") == "open"
    ]
    if opened != EXPECTED_OPEN:
        problems.append(
            f"policy: open types must be {EXPECTED_OPEN!r}, got {opened!r}"
        )

    return problems


def validate(data) -> list[str]:
    return check_shape(data) + check_mime_hierarchy(data) + check_policy(data)


def decided_types(data: dict) -> list[dict]:
    return [entry for entry in data.get("types", []) if isinstance(entry, dict) and entry.get("status") == "decided"]


def picker_mime_types(data: dict) -> list[str]:
    """Return safe subclass-aware picker MIME filters across decided entries (excludes compatibilityMimeTypes)."""
    result: list[str] = []
    seen: set[str] = set()
    for entry in decided_types(data):
        for mime in entry.get("mimeTypes", []):
            if mime not in seen:
                seen.add(mime)
                result.append(mime)
    return result


def inspect_ogg_opus_bos(header_bytes: bytes, content_validation: dict | None = None) -> tuple[bool, str]:
    """Verify in O(1) that header_bytes begins with an unmultiplexed RFC 7845 Ogg Opus BOS page."""
    if header_bytes.startswith(b"fLaC"):
        return False, "native FLAC stream (fLaC), not Ogg Opus"

    container_magic = bytes.fromhex(
        content_validation["containerMagicHex"] if content_validation else "4f676753"
    )
    if len(header_bytes) < 28 or not header_bytes.startswith(container_magic):
        return False, "missing OggS container capture pattern"
    if header_bytes[4] != 0:
        return False, f"unsupported Ogg stream_structure_version {header_bytes[4]}"

    header_type = header_bytes[5]
    if (header_type & 0x02) == 0 or (header_type & 0x01) != 0:
        return False, "first Ogg page is not a fresh Beginning-of-Stream (BOS) page"

    page_segments = header_bytes[26]
    seg_table_end = 27 + page_segments
    if len(header_bytes) < seg_table_end:
        return False, "truncated Ogg page segment table"

    payload_len = sum(header_bytes[27:seg_table_end])
    page0_end = seg_table_end + payload_len
    if payload_len == 0 or len(header_bytes) < page0_end:
        return False, "truncated or empty Ogg BOS payload"

    bos_payload = header_bytes[seg_table_end:page0_end]
    rejected_hex = (
        content_validation["rejectedBosMagicHex"]
        if content_validation
        else [
            "7f464c4143",
            "807468656f7261",
            "6669736865616400",
            "01766964656f000000",
            "4242434400",
            "806461616c61",
            "01766f72626973",
            "5370656578202020",
        ]
    )
    for bad_hex in rejected_hex:
        bad_magic = bytes.fromhex(bad_hex)
        if bos_payload.startswith(bad_magic):
            if bad_hex == "7f464c4143":
                return False, "undecided FLAC-in-Ogg stream"
            if bad_hex in ("807468656f7261", "01766964656f000000", "4242434400", "806461616c61"):
                return False, "unsupported Ogg video stream"
            if bad_hex == "6669736865616400":
                return False, "unsupported Ogg Skeleton multiplexed stream"
            return False, f"unsupported Ogg codec BOS magic {bad_hex}"

    accepted_magics = [
        bytes.fromhex(hx)
        for hx in (
            content_validation["acceptedBosMagicHex"]
            if content_validation
            else ["4f70757348656164"]
        )
    ]
    if not any(bos_payload.startswith(ok_magic) for ok_magic in accepted_magics):
        return False, "unrecognized non-Opus Ogg BOS stream"
    if bos_payload.startswith(b"OpusHead"):
        if len(bos_payload) < 19:
            return False, "truncated OpusHead identification header (< 19 bytes)"
        if (bos_payload[8] & 0xF0) != 0:
            return False, f"unsupported OpusHead major version in byte {bos_payload[8]}"

    if (header_type & 0x04) != 0:
        return False, "first Ogg page prematurely ends stream before OpusTags page"
    if len(header_bytes) < page0_end + 28 or header_bytes[page0_end:page0_end + 4] != container_magic:
        return False, "missing or corrupt second Ogg page header"
    if header_bytes[page0_end + 4] != 0:
        return False, f"unsupported second Ogg page version {header_bytes[page0_end + 4]}"
    next_header_type = header_bytes[page0_end + 5]
    if (next_header_type & 0x02) != 0:
        return False, "multiplexed Ogg container with multiple concurrent BOS streams"
    if (next_header_type & 0x01) != 0:
        return False, "unexpected continued packet on second Ogg page"

    next_segments = header_bytes[page0_end + 26]
    next_payload_start = page0_end + 27 + next_segments
    second_magic = bytes.fromhex(
        content_validation["secondPageMagicHex"] if content_validation else "4f70757354616773"
    )
    if len(header_bytes) < next_payload_start + len(second_magic):
        return False, "truncated second Ogg page before OpusTags magic"
    if not header_bytes[next_payload_start:next_payload_start + len(second_magic)] == second_magic:
        return False, "second Ogg page does not begin with OpusTags comment header"

    return True, "opus"


def inspect_native_flac_header(header_bytes: bytes, header_validation: dict | None = None) -> tuple[bool, str]:
    """Verify that header_bytes begins with a native FLAC stream marker and a STREAMINFO block (RFC 9639)."""
    hv = header_validation or {}
    magic = bytes.fromhex(hv.get("magicHex", FLAC_MAGIC_HEX))
    min_probe = hv.get("minProbeBytes", FLAC_MIN_PROBE_BYTES)
    block_type_expected = hv.get("firstMetadataBlockType", FLAC_STREAMINFO_BLOCK_TYPE)
    length_expected = hv.get("streamInfoLength", FLAC_STREAMINFO_LENGTH)

    if header_bytes.startswith(b"OggS"):
        return False, "Ogg container (Ogg FLAC or other Ogg stream), not native FLAC"
    if header_bytes.startswith(b"ID3"):
        return False, "ID3v2-prefixed stream is not a conformant native FLAC file"
    if not header_bytes.startswith(magic):
        return False, "missing native fLaC stream marker"
    if len(header_bytes) < min_probe:
        return False, f"truncated native FLAC header (< {min_probe} bytes)"
    block_type = header_bytes[4] & 0x7F
    if block_type != block_type_expected:
        return False, f"first FLAC metadata block is type {block_type}, not STREAMINFO"
    length = int.from_bytes(header_bytes[5:8], "big")
    if length != length_expected:
        return False, f"STREAMINFO length {length} != {length_expected}"
    sample_rate = (header_bytes[18] << 12) | (header_bytes[19] << 4) | (header_bytes[20] >> 4)
    if sample_rate == 0:
        return False, "STREAMINFO sample rate is 0"
    return True, "flac"


def validate_import_candidate(
    data: dict,
    filename: str,
    mime_type: str | None = None,
    header_bytes: bytes | None = None,
) -> tuple[bool, str | None, str]:
    """Validate an import file candidate against decided extensions, MIME rules, Ogg contentValidation, and native headerValidation."""
    basename = filename.rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    dot = basename.rfind(".")
    ext = basename[dot:].lower() if dot > 0 else ""

    decided_by_ext: dict[str, dict] = {}
    for entry in decided_types(data):
        for item_ext in entry.get("extensions", []):
            decided_by_ext[item_ext] = entry

    open_by_ext: dict[str, str] = {}
    open_mimes: set[str] = set()
    for entry in data.get("types", []):
        if isinstance(entry, dict) and entry.get("status") == "open":
            eid = str(entry.get("id"))
            for item_ext in entry.get("extensions", []):
                open_by_ext[item_ext] = eid
            for m in entry.get("mimeTypes", []):
                open_mimes.add(m)
                open_mimes.add(canonical_xdg_mime(m))

    base_mime = mime_type.split(";", 1)[0].strip().lower() if isinstance(mime_type, str) and mime_type.strip() else None

    if base_mime is not None:
        if base_mime.startswith("video/"):
            return False, None, f"rejected video MIME type {base_mime!r}"
        if base_mime in open_mimes or canonical_xdg_mime(base_mime) in open_mimes:
            return False, None, f"rejected open MIME type {base_mime!r}"

    if ext in open_by_ext:
        return False, None, f"rejected extension {ext!r} belonging to open type {open_by_ext[ext]!r}"

    entry = decided_by_ext.get(ext)
    if entry is None:
        return False, None, f"unsupported extension {ext!r}"

    cv = entry.get("contentValidation")
    if isinstance(cv, dict):
        if ext in cv.get("rejectedExtensions", []):
            return False, None, f"rejected extension {ext!r}"
        if base_mime is not None:
            for prefix in cv.get("rejectedMimePrefixes", []):
                if base_mime.startswith(prefix):
                    return False, None, f"rejected MIME prefix {prefix!r} ({base_mime!r})"

    safe_mimes = set(entry.get("mimeTypes", []))
    compat_mimes = set(entry.get("compatibilityMimeTypes", []))
    if base_mime is not None and base_mime not in safe_mimes and base_mime not in compat_mimes:
        return False, None, f"MIME type {base_mime!r} is not accepted for {entry['id']!r}"

    hv = entry.get("headerValidation")
    if isinstance(hv, dict):
        if base_mime is not None and base_mime in hv.get("rejectedMimeTypes", []):
            return False, None, f"rejected MIME type {base_mime!r} for {entry['id']!r}"
        if header_bytes is None:
            return False, None, f"header validation required for {entry['id']!r} input ({ext})"
        ok, detail = inspect_native_flac_header(header_bytes, hv)
        if not ok:
            return False, None, f"header validation failed for {entry['id']!r}: {detail}"

    if isinstance(cv, dict):
        needs_sniff = (
            ext in cv.get("ambiguousExtensions", [])
            or base_mime is None
            or base_mime in compat_mimes
        )
        if needs_sniff and header_bytes is None:
            return False, None, f"content validation required for ambiguous {entry['id']!r} input ({ext})"
        if header_bytes is not None:
            ok, detail = inspect_ogg_opus_bos(header_bytes, cv)
            if not ok:
                return False, None, f"content validation failed for {entry['id']!r}: {detail}"

    return True, str(entry["id"]), "accepted"


def summary(data: dict) -> str:
    decided = decided_types(data)
    opened = [e for e in data.get("types", []) if isinstance(e, dict) and e.get("status") == "open"]
    dec_exts = [ext for e in decided for ext in e.get("extensions", [])]
    open_exts = [ext for e in opened for ext in e.get("extensions", [])]
    open_part = f"{len(opened)} open: {', '.join(open_exts)}" if opened else "0 open"
    return (
        f"{len(data.get('types', []))} import types "
        f"({len(decided)} decided: {', '.join(dec_exts)}; {open_part})"
    )


def _make_ogg_page(payload: bytes, *, header_type: int = 0x02, serial: int = 1, seq: int = 0) -> bytes:
    assert len(payload) <= 255
    return (
        b"OggS\x00"
        + bytes([header_type])
        + b"\x00" * 8
        + serial.to_bytes(4, "little")
        + seq.to_bytes(4, "little")
        + b"\x00" * 4
        + b"\x01"
        + bytes([len(payload)])
        + payload
    )


def _make_flac_header(*, block_header: bytes = b"\x00\x00\x00\x22", sample_rate: int = 44100) -> bytes:
    """fLaC + STREAMINFO header (4096-sample blocks, 2 channels, 16 bits per sample, unknown length/MD5)."""
    rate_and_format = (sample_rate << 44) | (1 << 41) | (15 << 36)
    streaminfo = (
        (4096).to_bytes(2, "big") * 2
        + b"\x00" * 6
        + rate_and_format.to_bytes(8, "big")
        + b"\x00" * 16
    )
    assert len(streaminfo) == FLAC_STREAMINFO_LENGTH
    return b"fLaC" + block_header + streaminfo


def self_test() -> None:
    committed = load_strict_json(HERE / "import-types.json")
    assert validate(committed) == [], validate(committed)

    def problems(mutate):
        doc = copy.deepcopy(committed)
        mutate(doc)
        return validate(doc)

    assert any("schema" in p for p in problems(lambda d: d.update(schema="wrong")))
    assert any("version" in p for p in problems(lambda d: d.update(version="v1")))
    assert any("platforms" in p for p in problems(lambda d: d.update(platforms=["gnome", "mac"])))
    assert any("extensions" in p for p in problems(lambda d: d["types"][1].update(extensions=["mp3"])))
    assert any("extensions" in p for p in problems(lambda d: d["types"][1].update(extensions=[".MP3"])))
    assert any("duplicate extension" in p for p in problems(lambda d: d["types"][1]["extensions"].append(".ogg")))
    assert any("mimeTypes" in p for p in problems(lambda d: d["types"][1].update(mimeTypes=[])))
    assert any("mimeTypes" in p for p in problems(lambda d: d["types"][1].update(mimeTypes=["audio/*"])))
    assert any("video subclass 'video/ogg'" in p for p in problems(
        lambda d: d["types"][0].update(
            mimeTypes=["audio/opus", "application/ogg"],
            compatibilityMimeTypes=["audio/ogg"],
        )
    ))
    assert any("unsupported Ogg audio subclass 'audio/x-flac+ogg'" in p for p in problems(
        lambda d: d["types"][0].update(
            mimeTypes=["audio/opus", "audio/ogg"],
            compatibilityMimeTypes=["application/ogg"],
        )
    ))
    assert any("utis" in p for p in problems(lambda d: d["types"][1].update(utis=[])))
    assert any("too broad" in p for p in problems(lambda d: d["types"][1].update(utis=["public.audio"])))
    assert any("policy: decided types" in p for p in problems(
        lambda d: d["types"][4].update(status="open", open=["D-938"]) or d["types"][4].pop("decisions")
    ))
    assert any("must cite 'D-938'" in p for p in problems(lambda d: d["types"][4].update(decisions=["L-25"])))
    assert any("decided import extension of 'flac'" in p for p in problems(
        lambda d: d["types"][0]["contentValidation"]["rejectedExtensions"].append(".flac")
    ))
    assert any("must specify headerValidation" in p for p in problems(lambda d: d["types"][4].pop("headerValidation")))

    opus_bos = _make_ogg_page(b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00")
    opus_tags = _make_ogg_page(b"OpusTags\x00\x00\x00\x00\x00\x00\x00\x00", header_type=0x00, seq=1)
    theora_bos = _make_ogg_page(b"\x80theora\x03\x02\x01" + b"\x00" * 32)
    ogg_flac_bos = _make_ogg_page(b"\x7fFLAC\x01\x00\x00\x01fLaC" + b"\x00" * 34)

    assert validate_import_candidate(committed, "talk.opus", "audio/x-opus+ogg", opus_bos + opus_tags)[:2] == (True, "opus-ogg")
    assert validate_import_candidate(committed, "talk.ogg", "audio/ogg", opus_bos + opus_tags)[:2] == (True, "opus-ogg")
    assert not validate_import_candidate(committed, "clip.ogv", "video/ogg", theora_bos)[0]
    assert not validate_import_candidate(committed, "clip.ogg", "audio/ogg", theora_bos)[0]
    flac_header = _make_flac_header()
    assert validate_import_candidate(committed, "track.flac", "audio/flac", flac_header)[:2] == (True, "flac")
    assert not validate_import_candidate(committed, "track.flac", "audio/flac", flac_header[:41])[0]
    assert not validate_import_candidate(committed, "track.flac", "audio/flac", b"fLaC" + b"\x00" * 38)[0]
    assert not validate_import_candidate(committed, "track.flac", "audio/x-flac+ogg", flac_header)[0]
    assert not validate_import_candidate(committed, "track.flac", "audio/flac", ogg_flac_bos)[0]
    assert not validate_import_candidate(committed, "track.ogg", "audio/ogg", flac_header)[0]
    assert not validate_import_candidate(committed, "track.ogg", "audio/ogg", ogg_flac_bos)[0]
    print("self-test: ok")


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        self_test()
        return 0
    paths = [a for a in argv if not a.startswith("--")]
    path = Path(paths[0]) if paths else HERE / "import-types.json"
    try:
        data = load_strict_json(path)
    except (OSError, ValueError) as error:
        print(f"{path}: {error}")
        return 1
    problems = validate(data)
    for problem in problems:
        print(problem)
    if isinstance(data, dict) and isinstance(data.get("types"), list) and not problems:
        print(summary(data))
    print("FAILED" if problems else "OK")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
