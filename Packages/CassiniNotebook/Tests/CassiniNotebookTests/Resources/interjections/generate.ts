/**
 * Runs the REAL gocassini viewer pipeline on every *.words.json fixture next to
 * this file and writes <name>.expected.json in the neutral schema described in
 * README.md.
 *
 * Pipeline (all viewer code, imported directly; nothing re-implemented except
 * the two one-line presentation rules that live inside MeetingView.svelte and
 * cannot be imported from a .ts module: continuationRowKeys and the row
 * crosstalk badge selector, copied verbatim below):
 *
 *   cassini.words.v1 items
 *     -> manifest { transcript: { items } }                (a Cassini file's transcript body)
 *     -> buildTranscriptWordsFromPortable                   (one canonical segment per word)
 *     -> validateTranscriptWordsV1
 *     -> buildReadableTranscriptFromPortable                (viewer paragraph grouping)
 *     -> buildDisplayTranscriptFromArtifacts + validators   (as buildPortableLoadedArtifact)
 *     -> buildTranscriptIndex
 *     -> displaySegmentsForArtifact                         (meetingExport.ts: judged blocks,
 *                                                            repairTurnFinalWordInflation, sort)
 *     -> buildTranscriptRows                                (overlap.ts turn model)
 *
 * Run from anywhere:
 *   VIEWER=<gocassini>/cassini-viewer <gocassini>/node_modules/.bin/jiti generate.ts
 */
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const viewer = resolve(
  process.env.VIEWER ?? join(here, "../../gocassini/cassini-viewer"),
);

const portable = await import(join(viewer, "src/viewer/portable.ts"));
const transcript = await import(join(viewer, "src/core/transcript.ts"));
const meetingExport = await import(join(viewer, "src/viewer/meetingExport.ts"));
const overlap = await import(join(viewer, "src/core/overlap.ts"));

// MeetingView.svelte: `const CONTINUATION_GAP_MS = 60_000;` and continuationRowKeys.
const CONTINUATION_GAP_MS = 60_000;
function continuationRowKeys(rows: any[]): Set<string> {
  const keys = new Set<string>();
  for (let index = 1; index < rows.length; index += 1) {
    const previous = rows[index - 1]!;
    const current = rows[index]!;
    if (!current.speaker || previous.speaker !== current.speaker) {
      continue;
    }
    if (current.startMs - previous.endMs <= CONTINUATION_GAP_MS) {
      keys.add(current.key);
    }
  }
  return keys;
}
// MeetingView.svelte: rowSpeechBlocks + isRowLikelyCrosstalk.
function rowSpeechBlocks(row: any): any[] {
  return row.members.filter((m: any) => m.kind === "speech").map((m: any) => m.block);
}

interface WordsItem { speaker?: string; startMs: number; endMs: number; text: string }

function loadArtifact(items: WordsItem[]) {
  const manifest = {
    meeting: { durationMs: Math.max(0, ...items.map((i) => i.endMs)) },
    speakers: [],
    transcript: { items },
  };
  // Same steps, same order as buildPortableLoadedArtifact (loadArtifact.ts).
  const words = transcript.validateTranscriptWordsV1(
    portable.buildTranscriptWordsFromPortable(manifest, ""),
  );
  const rawReadable = portable.buildReadableTranscriptFromPortable(manifest, words);
  const displayTranscript = transcript.validateDisplayTranscriptV1(
    portable.buildDisplayTranscriptFromArtifacts(words, rawReadable),
  );
  const readableTranscript = transcript.validateReadableTranscriptV1(rawReadable);
  return {
    index: transcript.buildTranscriptIndex(words),
    readableTranscript,
    displayTranscript,
    // A Cassini file without provenance.wordTimings.endsBoundedByAudio === true.
    wordEndsBoundedByAudio: false,
  };
}

// Canonical word ids are "<segmentId>:w_0" and the segment id of item i is
// seg_%06d (buildTranscriptWordsFromPortable), so the id names the item index.
function wordIndicesOf(blocks: any[]): number[] {
  const out: number[] = [];
  for (const block of blocks) {
    for (const word of block.words ?? []) {
      const m = /^seg_(\d{6}):w_0$/.exec(word.id);
      if (!m) throw new Error(`unexpected canonical word id ${word.id}`);
      out.push(Number(m[1]));
    }
  }
  return out;
}

function generate(path: string) {
  const fixture = JSON.parse(readFileSync(path, "utf8"));
  if (fixture.format !== "cassini.words.v1") throw new Error(`${path}: not cassini.words.v1`);
  const items: WordsItem[] = fixture.items;
  const segments = meetingExport.displaySegmentsForArtifact(loadArtifact(items));
  const rows = overlap.buildTranscriptRows(segments);
  const continuation = continuationRowKeys(rows);

  const idByLabel = new Map<string, string>();
  for (const s of segments) if (s.speaker) idByLabel.set(s.speakerLabel, s.speaker);
  const speakerOf = (label: string) => idByLabel.get(label) ?? label;

  const seen = new Set<number>();
  const out = rows.map((row: any) => {
    const members = row.members.map((member: any) => {
      const blocks = member.kind === "speech" ? [member.block] : member.blocks;
      const wordIndices = wordIndicesOf(blocks);
      for (const i of wordIndices) {
        if (seen.has(i)) throw new Error(`${path}: item ${i} rendered twice`);
        seen.add(i);
      }
      const text = blocks.map((b: any) => b.text).join(" ");
      if (text !== wordIndices.map((i) => items[i]!.text).join(" ")) {
        throw new Error(`${path}: block text "${text}" is not its words`);
      }
      return member.kind === "speech"
        ? { kind: "words", wordIndices, text }
        : {
            kind: "interjection",
            speaker: speakerOf(member.speakerLabel),
            crosstalk: transcript.isLikelyCrosstalkAcrossBlocks(member.blocks),
            wordIndices,
            text,
          };
    });
    return {
      speaker: row.speaker,
      continuation: continuation.has(row.key),
      startMs: row.startMs,
      endMs: row.endMs,
      over: row.over.map(speakerOf),
      crosstalk: transcript.isLikelyCrosstalkAcrossBlocks(rowSpeechBlocks(row)),
      members,
    };
  });
  if (seen.size !== items.length) {
    const missing = items.map((_, i) => i).filter((i) => !seen.has(i));
    throw new Error(`${path}: items not rendered: ${missing.join(",")}`);
  }

  const name = basename(path, ".words.json");
  const expected = {
    format: "cassini.render-vector.v1",
    source: { repo: "codemyriad/gocassini", commit: process.env.GOCASSINI_COMMIT ?? "unknown" },
    fixture: `${name}.words.json`,
    rows: out,
    markdown: meetingExport.transcriptMarkdown({ title: name, dateLabel: "" }, segments),
  };
  writeFileSync(join(here, `${name}.expected.json`), JSON.stringify(expected, null, 2) + "\n");
  console.log(`${name}: ${out.length} rows`);
}

const only = process.argv.slice(2);
const fixtures = only.length
  ? only.map((p) => resolve(p))
  : readdirSync(here).filter((f) => f.endsWith(".words.json")).sort().map((f) => join(here, f));
for (const f of fixtures) generate(f);
