#!/usr/bin/env python3
"""Generate the brand RGBA table; W1 plumbing preserves a frozen, public baseline palette.

The compatibility appendix is a temporary no-visual-change exception to HARMONY 10.1.
It is extracted, never retyped. The preview must replace it with brand role aliases.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "f437a999d48b5489093e7d6b8326e32d7a00b69a"
TOKEN = "CassiniShared/Brand/tokens.json"
PIN = "CassiniShared/Brand/UPSTREAM.json"
OUTPUT = "CassiniShared/CassiniTokens.swift"
META = "CassiniShared/Brand/COMPATIBILITY.json"
APPLICATION = "CassiniShared/Brand/application.json"
ASSET = "Cassini/Resources/Assets.xcassets/AccentColor.colorset/Contents.json"
SOURCES = ("Cassini/Design/Tokens.swift", "Cassini/Design/Snackbar.swift",
           "CassiniShared/RecordingActivityColors.swift", "Cassini/Features/Library/NoteRow.swift", ASSET)


def baseline(path, root=ROOT):
    return subprocess.check_output(["git", "-C", str(root), "show", f"{BASELINE}:{path}"])


def extension(text):
    start = text.index("extension Color {")
    depth = 0
    for end in range(text.index("{", start), len(text)):
        depth += (text[end] == "{") - (text[end] == "}")
        if depth == 0:
            return text[start:end + 1]
    raise ValueError("unclosed baseline Color extension")


def role_name(role):
    parts = role.split("-")
    return parts[0] + "".join(part.title() for part in parts[1:])



PREVIEW_ALIASES = """
    static let paper = ground
    static let card = surface
    static let muted = ink2
    static let faint = ink3
    static let processing = accent
    static let toneOK = success
    static let toneInfo = accentInk
    static let toneWarn = warnInk
    static let toneError = error
    static let tonePlain = neutralInk
    // Structural transparency draws no colour; no fixed platform clear is required.
    static let canvasClear = ground.opacity(0)

    // L-08 remains a forced-dark policy. Its colours still come from the brand sheet.
    static let recordingBackground = CassiniTokens.color(.ground, forcedDark: true)
    static let recordingText = CassiniTokens.color(.ink, forcedDark: true)
    static let recordingSecondary = CassiniTokens.color(.ink2, forcedDark: true)
    static let recordingButtonWash = CassiniTokens.color(.neutralTint, forcedDark: true)
    static let recordingLine = CassiniTokens.color(.line, forcedDark: true)
    static let recordingAccent = CassiniTokens.color(.recordInk, forcedDark: true)
    static let recordingFinish = record
    static let recordingLive = recordingAccent
    static let unnamedSpeakerTint = speaker0
    static let unnamedSpeakerWash = avatar0
    static let speakerTints: [Color] = [speaker1, speaker2, speaker3, speaker4, speaker5, speaker6]
    static let speakerWashes: [Color] = [avatar1, avatar2, avatar3, avatar4, avatar5, avatar6]
    static let snackbarBackground = inverse
    static let snackbarText = onInverse
    static let snackbarAction = inverseAccent

    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

enum RecordingActivityColors {
    static let background = Color.recordingBackground
    static let live = Color.recordingAccent
    static let finish = Color.record
    static let secondary = Color.recordingSecondary
    static let button = Color.recordingButtonWash
}
"""


def render(root=ROOT):
    application = json.loads((root / APPLICATION).read_text())
    plumbing = application == {"mode": "plumbing", "compatibility_baseline": BASELINE}
    if not plumbing and application != {"mode": "preview"}:
        raise ValueError("unsupported brand application mode/baseline")
    raw = (root / TOKEN).read_bytes()
    pin = json.loads((root / PIN).read_text())
    digest = hashlib.sha256(raw).hexdigest()
    if pin.get("repository") != "https://github.com/codemyriad/cassini-ux" or pin.get("path") != "brand/tokens.json":
        raise ValueError("unexpected brand pin source")
    if not re.fullmatch(r"[a-f0-9]{40}", pin.get("commit", "")) or pin.get("sha256") != digest:
        raise ValueError("brand pin/hash mismatch")
    tokens = json.loads(raw)["tokens"]
    active = {k: v for k, v in tokens.items() if v["status"] in ("decided", "placeholder")}
    if len(active) != 49 or len(active) != len(tokens):
        raise ValueError("expected all 49 decided brand roles")
    for role, pair in active.items():
        if not re.fullmatch(r"[a-z]+(?:-[a-z0-9]+)*", role):
            raise ValueError("invalid role name")
        for mode in ("light", "dark"):
            if not re.fullmatch(r"#[A-Fa-f0-9]{6}(?:[A-Fa-f0-9]{2})?", pair[mode]):
                raise ValueError(f"invalid {role} {mode} RGBA")
    sources = {path: baseline(path, root) for path in SOURCES} if plumbing else {}
    meta = {"mode": "plumbing-no-visual-change", "baseline_commit": BASELINE,
            "exception": "Temporary compatibility palette; replace with pinned brand roles in W1 preview.",
            "sources": {path: hashlib.sha256(data).hexdigest() for path, data in sources.items()}}
    roles = "\n".join(f'        case {role_name(k)} = "{k}"' for k in active)
    def packed(value):
        return value[1:] + ("FF" if len(value) == 7 else "")
    rows = "\n".join(f'        .{role_name(k)}: (0x{packed(v["light"])}, 0x{packed(v["dark"])}),' for k, v in active.items())
    header = f'''// GENERATED by scripts/generate-brand-colors.py; do not edit.
// Brand: cassini-ux {pin['commit']}, brand/tokens.json SHA256 {digest}.
// Application mode: {application['mode']}. {('Compatibility baseline ' + BASELINE + '; hashes in Brand/COMPATIBILITY.json.') if plumbing else 'HARMONY 10.1 staging exception closed; all colours derive from pinned roles.'}
import SwiftUI

enum CassiniTokens {{
    enum Role: String, CaseIterable {{
{roles}
    }}
    private final class BundleAnchor: NSObject {{}}
    static let bundle = Bundle(for: BundleAnchor.self)
    private static let values: [Role: (UInt32, UInt32)] = [
{rows}
    ]
    static func color(_ role: Role, forcedDark: Bool = false) -> Color {{
        guard let pair = values[role] else {{ preconditionFailure("Missing generated brand role") }}
        return Color(light: rgba(forcedDark ? pair.1 : pair.0), dark: rgba(pair.1))
    }}
    private static func rgba(_ value: UInt32) -> UIColor {{
        UIColor(red: CGFloat((value >> 24) & 255) / 255, green: CGFloat((value >> 16) & 255) / 255,
                blue: CGFloat((value >> 8) & 255) / 255, alpha: CGFloat(value & 255) / 255)
    }}
}}

'''
    if not plumbing:
        aliases = "\n".join(f"    static let {role_name(role)} = CassiniTokens.color(.{role_name(role)})" for role in active)
        swift = header + "extension Color {\n" + aliases + PREVIEW_ALIASES
        colors = []
        for mode in ("light", "dark"):
            raw = active["accent"][mode].removeprefix("#")
            color = {"idiom": "universal", "color": {"color-space": "srgb", "components": {
                "red": f"0x{raw[:2]}", "green": f"0x{raw[2:4]}", "blue": f"0x{raw[4:6]}", "alpha": "1.000"}}}
            if mode == "dark": color["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            colors.append(color)
        asset = {"colors": colors, "info": {"author": "xcode", "version": 1}}
        return {OUTPUT: swift.encode(), ASSET: (json.dumps(asset, indent=2) + "\n").encode()}
    header += "// TEMPORARY plumbing compatibility, mechanically extracted from the frozen public baseline.\n"
    compatibility = [extension(sources[SOURCES[0]].decode()), extension(sources[SOURCES[1]].decode()),
                     sources[SOURCES[2]].decode().removeprefix("import SwiftUI\n").strip()]
    # Platform primitives are source-derived aliases, not new brand values. Keep the old exact draw output.
    all_source = "\n".join(v.decode() for k, v in sources.items() if k.endswith(".swift"))
    aliases = []
    for name in ("white", "black", "clear", "orange"):
        if not re.search(r"\." + name + r"\b", all_source):
            raise ValueError(f"platform alias {name} absent from frozen baseline")
        aliases.append(f"    static let compatibility{name.title()} = Color.{name}")
    swift = header + "\n\n".join(compatibility) + "\n\nextension Color {\n" + "\n".join(aliases) + "\n}\n"
    return {OUTPUT: swift.encode(), META: (json.dumps(meta, indent=2) + "\n").encode(), ASSET: sources[ASSET]}


# No source-file allowlist. Only the generated table is exempt; native chrome/artwork is not scanned.
# Colour enum cases (e.g. SpeakerTint.blue) and model labels are not platform colour expressions.
COLOR_TYPES = r"(?:Color|UIColor|CIColor|CGColor)"
COLOR_COMPONENTS = r"(?:red|srgbRed|white|gray|hue|displayP3|\.sRGB|\.sRGBLinear|\.displayP3)"
FIXED_NAMES = r"(?:red|blue|green|yellow|gray|grey|darkGray|lightGray|purple|pink|brown|cyan|magenta|mint|teal|indigo|white|black|clear|orange)"
LITERAL = re.compile(
    # Explicit and inferred initializers: the component labels identify colour construction.
    rf"\b{COLOR_TYPES}(?:\s*\.\s*init)?\s*\(\s*{COLOR_COMPONENTS}\s*[:,]|"
    rf"\.init\s*\(\s*{COLOR_COMPONENTS}\s*[:,]|"
    r"#colorLiteral\s*\(|"
    rf"\b{COLOR_TYPES}\.(?:system\w+|secondarySystem\w+|label|secondaryLabel|tertiaryLabel|{FIXED_NAMES})\b|"
    r"\.(?:white|black|clear|orange|system(?:Red|Blue|Green|Orange|Yellow|Purple|Pink|Brown|Teal|Indigo|Gray[0-9]*))\b|"
    rf"(?:foregroundStyle|foregroundColor|background|tint|fill|stroke|strokeBorder|color|{COLOR_TYPES})\(\.{FIXED_NAMES}\b|"
    r"#[a-fA-F0-9]{6}(?:[a-fA-F0-9]{2})?\b|\b0x[a-fA-F0-9]{6,8}\b")


def check_literals(root=ROOT):
    failures = []
    for directory in ("Cassini", "CassiniShared", "CassiniActivity"):
        for path in sorted((root / directory).rglob("*.swift")):
            if path.relative_to(root).as_posix() == OUTPUT:
                continue
            code = "\n".join(line.split("//", 1)[0] for line in path.read_text().splitlines())
            for match in LITERAL.finditer(code):
                number = code.count("\n", 0, match.start()) + 1
                failures.append(f"{path.relative_to(root)}:{number}: fixed colour outside generated table")
        for asset in sorted((root / directory).rglob("*.colorset/Contents.json")):
            if asset.relative_to(root).as_posix() != ASSET:
                failures.append(f"{asset.relative_to(root)}: colour asset outside generated outputs")
    if failures:
        raise ValueError("\n".join(failures))


def check_generated(root=ROOT):
    if json.loads((root / APPLICATION).read_text()).get("mode") == "preview" and (root / META).exists():
        raise ValueError("preview must not retain compatibility metadata")
    for path, data in render(root).items():
        if not (root / path).exists() or (root / path).read_bytes() != data:
            raise ValueError(f"generated drift: {path}; run scripts/generate-brand-colors.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if args.check:
            check_generated()
        else:
            outputs = render()
            if META not in outputs:
                (ROOT / META).unlink(missing_ok=True)
            for path, data in outputs.items():
                (ROOT / path).write_bytes(data)
        check_literals()
    except (ValueError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
