#!/usr/bin/env python3
"""Writes the *.words.json fixtures of this vector (cassini.words.v1).

acknowledgment and competing are the GNOME fixtures from
origin/fix/inline-transcript-interjections (tests/ux/interjections), with every
item that held whitespace split into one item per word, the item's time shared
equally between its words. The other four are synthetic.
Speakers are ada/ben/cy only; text is English. Items are written sorted by
startMs (ties never occur), which is the order the viewer groups them in.

Run: python3 -I make_fixtures.py [path-to-source-fixture-dir]
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORD_MS = 400


def item(speaker, start, end, text):
    assert text and not re.search(r"\s", text), text
    assert end >= start
    return {"speaker": speaker, "startMs": start, "endMs": end, "text": text}


def split_whitespace_items(items):
    out = []
    for it in items:
        words = it["text"].split()
        if len(words) == 1:
            out.append(dict(it, text=words[0]))
            continue
        span = it["endMs"] - it["startMs"]
        start = it["startMs"]
        for i, w in enumerate(words):
            end = it["startMs"] + round(span * (i + 1) / len(words))
            out.append(dict(it, startMs=start, endMs=end, text=w))
            start = end
    return out


def run(speaker, text, start, word_ms=WORD_MS):
    """Consecutive words of one speaker, back to back, word_ms each."""
    items, t = [], start
    for w in text.split():
        items.append(item(speaker, t, t + word_ms, w))
        t += word_ms
    return items, t


def doc(items):
    items = sorted(items, key=lambda i: i["startMs"])
    starts = [i["startMs"] for i in items]
    assert len(set(starts)) == len(starts), "start ties make file order ambiguous"
    return {"format": "cassini.words.v1", "language": "en", "items": items}


def write(name, document):
    with open(os.path.join(HERE, f"{name}.words.json"), "w") as f:
        json.dump(document, f, indent=2, ensure_ascii=False)
        f.write("\n")


def from_gnome(name):
    raw = subprocess.check_output(
        ["git", "-C", "/home/silvio/dev/cassini-gnome", "show",
         f"origin/fix/inline-transcript-interjections:tests/ux/interjections/{name}.words.json"])
    src = json.loads(raw)
    return {"format": src["format"], "language": src["language"],
            "items": split_whitespace_items(src["items"])}


# ---------------------------------------------------------------- monologue
MONO_A = (
    "Good morning everyone, this is the weekly update for the desktop release. "
    "We finished the packaging work for the three Linux formats on Tuesday and the builds are green. "
    "The installer now checks the free disk space before it downloads the speech model. "
    "On the recording side we fixed the bug where a muted microphone produced an empty file. "
    "The new level meter is in the main window and it responds within a few frames. "
    "We also cut the start-up time by loading the model in the background. "
    "Translations for all five languages are complete and reviewed by native speakers. "
    "The remaining work is mostly polish and a few accessibility fixes in the settings dialog."
)
MONO_B = (
    "For next week the plan is simple. "
    "We will run the full test matrix on the release candidate and collect feedback from the internal testers "
    "before we decide on the final date."
)
MONO_C = (
    "One more thing before we move on. "
    "Please file every crash you see, even the ones that look familiar, so we can track them properly."
)

# ---------------------------------------------------------------- overlapping
OVL_A1 = MONO_A
OVL_A2 = (
    "That brings me to the question of the release date, which I think we should settle today "
    "because the store review takes about a week."
)
OVL_A3 = (
    "If we submit on Friday the build could be live by the following Thursday, "
    "and that gives us enough time to fix anything the testers report in the first days. "
    "I would rather move fast and ship small fixes after the launch than hold everything back for another month."
)
OVL_B = (
    "I agree that we should pick a date, but I am worried about the audio regression on older laptops. "
    "Two testers reported crackling during long recordings and we still do not know the cause. "
    "If we ship with that problem the first reviews will be about sound quality and nothing else. "
    "I would like one more week to reproduce it on the hardware we have in the office. "
    "After that I am happy with any date you choose, as long as the fix is in the build we submit."
)


def main():
    write("acknowledgment", from_gnome("acknowledgment"))
    write("competing", from_gnome("competing"))

    # 1. long single-speaker monologue: two producer paragraphs with no pause
    #    between them, a 5 s pause, a short closing paragraph whose last word
    #    carries an inflated end.
    a, t = run("ada", MONO_A, 0)
    b, t = run("ada", MONO_B, t)
    c, t = run("ada", MONO_C, t + 5000)
    c[-1] = item("ada", c[-1]["startMs"], c[-1]["startMs"] + 3000, c[-1]["text"])
    write("monologue", doc(a + b + c))

    # 2. two long overlapping turns: ada holds the floor alone for two
    #    paragraphs, ben starts 200 ms into one of her words and both talk for
    #    about 25 s, then ben carries on alone.
    a1, t = run("ada", OVL_A1, 0)
    a2, t = run("ada", OVL_A2, t)
    a3, ada_end = run("ada", OVL_A3, t)
    bb, _ = run("ben", OVL_B, t + 200)
    assert bb[-1]["endMs"] > ada_end
    write("overlapping-turns", doc(a1 + a2 + a3 + bb))

    # 3. a brief reply that must not produce "over": ben's first word overlaps
    #    ada's last by 100 ms (under the 150 ms floor) and his inflated
    #    turn-final word would overlap ada's next turn by 400 ms if the timing
    #    repair did not clip it.
    q, t = run("ada", "Can you send me the updated release notes before the review today?", 0)
    r = [item("ben", t - 100, t + 300, "Yes,"), item("ben", t + 300, t + 3200, "today.")]
    f, _ = run("ada", "Great, thank you.", t + 2800)
    write("brief-reply", doc(q + r + f))

    # 4. seams: ben says "Right." inside ada's turn with a 400 ms seam (ada
    #    rejoins, ben is a chip); later ben says "Okay." with a 450 ms seam
    #    (no rejoin, three separate rows). cy closes.
    p1, t = run("ada", "The first build is ready for testing,", 0)
    i1 = [item("ben", t, t + 400, "Right.")]
    p2, t = run("ada", "and the second one should be ready tonight.", t + 400)
    p3, t = run("ada", "I will also update the download page,", t + 1200)
    i2 = [item("ben", t, t + 450, "Okay.")]
    p4, t = run("ada", "and then send the link to the testers.", t + 450)
    p5, _ = run("cy", "Thanks, that works for me.", t + 1500)
    write("seam-gap", doc(p1 + i1 + p2 + p3 + i2 + p4 + p5))


if __name__ == "__main__":
    main()
