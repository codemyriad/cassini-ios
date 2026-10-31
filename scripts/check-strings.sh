#!/bin/bash
# Fails when the string catalogs and the sources disagree, or when a string is not fully translated.
#
#   scripts/check-strings.sh
#
# Checks every table in Cassini/Resources/Strings, and Cassini/Resources/InfoPlist.xcstrings (the permission prompts):
#   - every key has a value in each of the app's languages (it, fr, es, pt-BR, pt-PT besides the English source), each
#     in state "translated" (not "new" or "needs_review"), and no key is marked stale;
#   - a plural has exactly the language's CLDR categories (en: one, other; it, fr, es, pt: one, many, other);
#   - each translation takes the English arguments with the same types, in any order (%2$@ before %1$lld is fine). A
#     `one` form may leave out the count only where `one` is the number 1 alone (it, es, pt-PT: "un file"); in French
#     and Brazilian Portuguese `one` also covers 0, so it keeps it;
#   - "Cassini" (and "Cassini talk") stays as it is in every language (D45, D50);
#   - every key is used by the sources (`xcstringstool extract`), and every string the sources ask a table for is in it;
#   - no source asks for a string outside the tables (the default Localizable table), so every literal on screen is
#     in a catalog;
#   - InfoPlist's keys are usage descriptions that Cassini/Resources/Info.plist has, with its text as the English.
# scripts/test.sh fast runs it before swift test.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find "$root/Cassini" "$root/CassiniShared" "$root/CassiniActivity" -name '*.swift' | sort)
xcrun xcstringstool extract --modern-localizable-strings --SwiftUI "${sources[@]}" --output-directory "$work" > /dev/null
plutil -convert json -o "$work/Info.json" "$root/Cassini/Resources/Info.plist"

/usr/bin/python3 -I - "$root/Cassini/Resources/Strings" "$work" "$root/Cassini/Resources/InfoPlist.xcstrings" "$work/Info.json" <<'PY'
import glob, json, os, re, sys

tables_dir, extracted_dir, info_catalog, info_plist = sys.argv[1:5]
problems = []

# The CLDR plural categories of each language's integers (CLDR 46). Italian, Spanish and Portuguese gained `many` for
# millions ("1 milione di file"), French has it too; `one` is 0 and 1 in French and Brazilian Portuguese, and 1 alone
# in Italian, Spanish and European Portuguese.
LANGUAGES = {"it": "Italian", "fr": "French", "es": "Spanish", "pt-BR": "Brazilian Portuguese",
             "pt-PT": "European Portuguese"}
PLURALS = {"en": {"one", "other"}, **{language: {"one", "many", "other"} for language in LANGUAGES}}
ONE_IS_ONLY_1 = {"it", "es", "pt-PT"}
NEVER_TRANSLATED = ["Cassini talk", "Cassini"]

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

def arguments(value):
    """{argument number: type} of a format string; %1$@ names its argument, a bare %@ takes the next one."""
    taken, following = {}, 1
    for position, kind in re.findall(r"%(?:(\d+)\$)?(lld|ld|d|@|f|s)", value.replace("%%", "")):
        number = int(position) if position else following
        following = number + 1
        taken[number] = kind
    return taken

def units(localization):
    """(form, stringUnit) for a localization: the plain value, or each plural (or device) form."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, forms in localization.get("variations", {}).items():
        for form, variation in forms.items():
            yield f" [{kind} {form}]", variation.get("stringUnit", {})

def check_entry(name, key, entry):
    if entry.get("extractionState") == "stale":
        problems.append(f"{name} is marked stale")
    localizations = entry.get("localizations", {})
    english = localizations.get("en", {})
    english_forms = english.get("variations", {}).get("plural", {})
    if english_forms and set(english_forms) != PLURALS["en"]:
        problems.append(f"{name}: the English plural has {sorted(english_forms)}, not {sorted(PLURALS['en'])}")
    english_text = (english_forms.get("other", {}).get("stringUnit", {}).get("value", key) if english_forms
                    else english.get("stringUnit", {}).get("value", key))
    reference = arguments(english_text)
    for language, language_name in LANGUAGES.items():
        localization = localizations.get(language)
        if not localization:
            problems.append(f"{name} has no {language_name}")
            continue
        forms = localization.get("variations", {}).get("plural")
        if english_forms and set(forms or {}) != PLURALS[language]:
            problems.append(f"{name}: the {language_name} plural has {sorted(forms or {})}, not {sorted(PLURALS[language])}")
        elif not english_forms and forms:
            problems.append(f"{name}: {language_name} has a plural where English has none")
        for form, unit in units(localization):
            label = f"{name}{form}: {language_name}"
            state = unit.get("state")
            if state != "translated":
                problems.append(f"{label} is {state or 'empty'}, not translated")
            value = unit.get("value", "")
            if not value.strip():
                problems.append(f"{label} is empty")
                continue
            taken = arguments(value)
            leaves_out_the_count = (form == " [plural one]" and language in ONE_IS_ONLY_1
                                    and set(taken) < set(reference) and all(reference[n] == kind for n, kind in taken.items()))
            if taken != reference and not leaves_out_the_count:
                problems.append(f"{label} takes {taken}, English {reference}: “{value}”")
            for word in NEVER_TRANSLATED:
                if word in english_text:
                    if word not in value:
                        problems.append(f"{label} drops “{word}”: “{value}”")
                    break

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
        check_entry(f"{table}: “{key}”", key, entry)

with open(info_catalog) as f:
    info_keys = json.load(f)["strings"]
with open(info_plist) as f:
    info = json.load(f)
for key in sorted(k for k in info if k.endswith("UsageDescription")):
    if key not in info_keys:
        problems.append(f"InfoPlist: the usage description {key} is not translated")
for key, entry in sorted(info_keys.items()):
    english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
    if key not in info:
        problems.append(f"InfoPlist: {key} is not in Info.plist (stale: remove it)")
    elif english != info[key]:
        problems.append(f"InfoPlist: {key}'s English “{english}” is not Info.plist's “{info[key]}”")
    check_entry(f"InfoPlist: {key}", english or key, entry)

for problem in problems:
    print(problem, file=sys.stderr)
if problems:
    print(f"{len(problems)} string catalog problem(s)", file=sys.stderr)
    sys.exit(1)
count = sum(len(json.load(open(p))["strings"]) for p in glob.glob(os.path.join(tables_dir, "*.xcstrings"))) + len(info_keys)
print(f"string catalogs: {count} keys, each in {len(LANGUAGES) + 1} languages, all translated and in use")
PY
