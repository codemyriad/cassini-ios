#!/bin/bash
# Fails when the string catalogs and the sources disagree, or when a string is not fully translated.
#
#   scripts/check-strings.sh
#
# Checks every table in Cassini/Resources/Strings:
#   - every key has an Italian value (each plural form too: one and other, and many where English has a plural),
#     in state "translated" (not "new" or "needs_review"), and no key is marked stale;
#   - Italian keeps the English placeholders (the same number of %@, %lld, ...);
#   - every key is used by the sources (`xcstringstool extract`), and every string the sources ask a table for is in it;
#   - no source asks for a string outside the tables (the default Localizable table), so every literal on screen is
#     in a catalog.
# scripts/test.sh fast runs it before swift test.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find "$root/Cassini" "$root/CassiniShared" "$root/CassiniActivity" -name '*.swift' | sort)
xcrun xcstringstool extract --modern-localizable-strings --SwiftUI "${sources[@]}" --output-directory "$work" > /dev/null

/usr/bin/python3 -I - "$root/Cassini/Resources/Strings" "$work" <<'PY'
import glob, json, os, re, sys

tables_dir, extracted_dir = sys.argv[1:3]
problems = []

# The sources' keys per table. Lightweight extraction cannot tell an interpolation's type, so it writes %arg where the
# catalog has %@ or %lld; keys are compared with every placeholder written as %arg.
def shape(key):
    return re.sub(r"%(\d+\$)?(lld|ld|d|@|f|s|arg)", "%arg", key)

used = {}
for path in glob.glob(os.path.join(extracted_dir, "*.stringsdata")):
    with open(path) as f:
        data = json.load(f)
    source = os.path.relpath(data.get("source", path), os.path.dirname(os.path.dirname(os.path.dirname(tables_dir))))
    for table, entries in data.get("tables", {}).items():
        for entry in entries:
            line = entry.get("location", {}).get("startingLine", "?")
            used.setdefault(table, {}).setdefault(shape(entry["key"]), f"{source}:{line}")

for key, where in sorted(used.pop("Localizable", {}).items(), key=lambda item: item[1]):
    problems.append(f"{where}: “{key}” is in no table (give it a table: \"…\")")

def placeholders(value):
    return sorted(re.sub(r"\d+\$", "", p) for p in re.findall(r"%(?:\d+\$)?(?:lld|ld|d|@|f|s)", value))

def units(localization):
    """(form, stringUnit) for a localization: the plain value, or each plural (or device) form."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, forms in localization.get("variations", {}).items():
        for form, variation in forms.items():
            yield f" [{kind} {form}]", variation.get("stringUnit", {})

for path in sorted(glob.glob(os.path.join(tables_dir, "*.xcstrings"))):
    table = os.path.basename(path)[: -len(".xcstrings")]
    with open(path) as f:
        catalog = json.load(f)
    keys = catalog["strings"]
    shaped = {shape(key) for key in keys}
    for key in sorted(shaped - set(used.get(table, {}))):
        problems.append(f"{table}: “{key}” is not used by any source (stale: remove it)")
    for key, where in sorted(used.get(table, {}).items()):
        if key not in shaped:
            problems.append(f"{where}: “{key}” is missing from {table}.xcstrings")
    for key, entry in sorted(keys.items()):
        name = f"{table}: “{key}”"
        if entry.get("extractionState") == "stale":
            problems.append(f"{name} is marked stale")
        localizations = entry.get("localizations", {})
        english = localizations.get("en", {})
        english_forms = english.get("variations", {}).get("plural", {})
        italian = localizations.get("it")
        if not italian:
            problems.append(f"{name} has no Italian")
            continue
        italian_forms = italian.get("variations", {}).get("plural")
        if english_forms:
            missing = {"one", "many", "other"} - set(italian_forms or {})
            if missing:
                problems.append(f"{name} lacks the Italian plural forms {', '.join(sorted(missing))}")
        reference = placeholders(english_forms.get("other", {}).get("stringUnit", {}).get("value", key)
                                 if english_forms else english.get("stringUnit", {}).get("value", key))
        for form, unit in units(italian):
            state = unit.get("state")
            if state != "translated":
                problems.append(f"{name}{form}: Italian is {state or 'empty'}, not translated")
            value = unit.get("value", "")
            if not value.strip():
                problems.append(f"{name}{form}: Italian is empty")
            elif placeholders(value) != reference and not (form.startswith(" [plural one]") and len(placeholders(value)) < len(reference)):
                problems.append(f"{name}{form}: Italian placeholders {placeholders(value)} differ from {reference}")

for problem in problems:
    print(problem, file=sys.stderr)
if problems:
    print(f"{len(problems)} string catalog problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"string catalogs: {sum(len(json.load(open(p))['strings']) for p in glob.glob(os.path.join(tables_dir, '*.xcstrings')))} keys, all translated and in use")
PY
