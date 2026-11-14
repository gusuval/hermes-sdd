// questions.mjs — `sdd questions sync|list|view`: the async questions of the stations (references/async-questions.md)
// travel with the repository. Node >= 18, no dependencies. Called from scripts/sdd.mjs (and from `sdd journal add`
// and `sdd accept --report`); returns an exit code.
//
// Why: `.sdd/` is git-ignored (it also holds runtime state: locks, junit, the ledger), but commits, requirements and the
// journal cite `Q-…` ids, and a tag must say what the customer was asked and what they chose (club, 11/2026: 79
// questions lived only in .sdd/questions-*.md, outside git). The source stays where every stage, the guard and the
// notary already read and write it; `sync` mirrors each `.sdd/questions-*.md` into `status/questions/` (versioned, next
// to the journal). The mirror is a record, not an authority: an answer there authorizes nothing (Art. 12 is a signed
// `test-edit` record in acceptance/decisions.jsonl).
//
// When it runs, so the copy lands in a commit that already happens:
//   - `sdd journal add --by …` (a person's decision: every gate of the notary journals it and then commits status/);
//   - `sdd accept --report …` (the FASE or delivery acceptance commits acceptance/ and status/);
//   - by hand: `sdd questions sync`.
// A copy is written only when its content changed, never deleted, so a run without questions leaves status/ untouched.
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import path from "node:path";

export const SOURCE_DIR = ".sdd";
export const MIRROR_DIR = "status/questions";
const FILE_RE = /^questions-[A-Za-z0-9._-]+\.md$/;
const HEAD_RE = /^(?:##\s+)?(Q-[A-Za-z][\w-]*-\d{3})\s+\[(OPEN|ANSWERED)\](.*)$/;

/** Question files of a directory: [{ name, abs }] sorted by name. */
export function questionFiles(dir) {
  let names = [];
  try { names = readdirSync(dir).filter((n) => FILE_RE.test(n)).sort(); } catch { return []; }
  return names.map((name) => ({ name, abs: path.join(dir, name) }));
}

/** Copies .sdd/questions-*.md into status/questions/ when the content differs. Returns the relative paths written. */
export function syncQuestions(root) {
  const written = [];
  for (const f of questionFiles(path.join(root, SOURCE_DIR))) {
    let text;
    try { text = readFileSync(f.abs, "utf8"); } catch { continue; }
    const rel = `${MIRROR_DIR}/${f.name}`;
    const dest = path.join(root, rel);
    let prev = null;
    try { prev = readFileSync(dest, "utf8"); } catch { /* new */ }
    if (prev === text) continue;
    mkdirSync(path.dirname(dest), { recursive: true });
    writeFileSync(dest, text);
    written.push(rel);
  }
  return written;
}

/** Blocks of one questions file: [{ id, state, skill, context, question, client, options[{letter, text, effect}], blocks, answer, applied }]. */
export function parseQuestions(text, file = "") {
  const out = [];
  let cur = null, opt = null;
  for (const raw of String(text || "").split("\n")) {
    const line = raw.replace(/\s+$/, "");
    const h = line.match(HEAD_RE);
    if (h) {
      const attrs = Object.fromEntries([...h[3].matchAll(/(\w+)=(\S+)/g)].map((m) => [m[1], m[2]]));
      cur = { id: h[1], state: h[2], skill: attrs.skill || null, context: attrs.context || null, file, question: "", client: "",
        options: [], blocks: "", answer: "", applied: "" };
      opt = null;
      out.push(cur); continue;
    }
    if (!cur) continue;
    if (/^#{1,2}\s/.test(line)) { cur = null; continue; }
    let m;
    if ((m = line.match(/^Question:\s*(.*)$/))) cur.question = m[1];
    else if ((m = line.match(/^Para el cliente:\s*(.*)$/i))) cur.client = m[1];
    else if ((m = line.match(/^\s*([A-Z])\)\s*(.*)$/))) { opt = { letter: m[1], text: m[2], effect: null }; cur.options.push(opt); }
    else if ((m = line.match(/^\s+efecto:\s*(.*)$/i)) && opt) opt.effect = m[1];
    else if ((m = line.match(/^Blocks:\s*(.*)$/))) cur.blocks = m[1];
    else if ((m = line.match(/^Answer:\s*(.*)$/))) cur.answer = m[1];
    else if ((m = line.match(/^Applied:\s*(.*)$/))) cur.applied = m[1];
  }
  return out;
}

/** Every question of the project: the live files of .sdd/, else the versioned mirror (a fresh clone has no .sdd/). */
export function loadQuestions(root) {
  let files = questionFiles(path.join(root, SOURCE_DIR));
  let from = SOURCE_DIR;
  if (!files.length) { files = questionFiles(path.join(root, MIRROR_DIR)); from = MIRROR_DIR; }
  const list = [];
  for (const f of files) {
    try { list.push(...parseQuestions(readFileSync(f.abs, "utf8"), `${from}/${f.name}`)); } catch { /* unreadable */ }
  }
  return { from, questions: list };
}

const oneLine = (s) => String(s || "").replace(/\|/g, "/").replace(/\s+/g, " ").trim() || "—";

/** `[NEEDS CLARIFICATION …]` markers still in spec/ (the pending part of spec/CLARIFICATIONS-PENDING.md): [{ file, line, text }]. */
export function specMarkers(root) {
  const out = [];
  const walk = (abs, depth) => {
    let es = [];
    try { es = readdirSync(abs, { withFileTypes: true }); } catch { return; }
    for (const e of es.sort((a, b) => a.name.localeCompare(b.name))) {
      if (e.name.startsWith(".")) continue;
      const p = path.join(abs, e.name);
      if (e.isDirectory() && depth < 6) walk(p, depth + 1);
      else if (e.isFile() && /\.md$/i.test(e.name) && !/^CLARIFICATIONS/i.test(e.name)) {
        let t = "";
        try { t = readFileSync(p, "utf8"); } catch { continue; }
        t.split("\n").forEach((l, i) => { if (/\[NEEDS CLARIFICATION/i.test(l)) out.push({ file: path.relative(root, p).split(path.sep).join("/"), line: i + 1, text: l.trim() }); });
      }
    }
  };
  walk(path.join(root, "spec"), 0);
  return out;
}

/** The generated view: open questions first (what is pending), then the decisions taken (answered). Markdown. */
export function renderView({ from, questions, markers = [] }) {
  const open = questions.filter((q) => q.state === "OPEN");
  const done = questions.filter((q) => q.state === "ANSWERED");
  const o = ["# Preguntas y decisiones", "",
    `> Vista generada por \`sdd questions view\` desde \`${from}/questions-*.md\`. No se edita a mano: se regenera.`, "",
    `## Pendientes (${open.length})`, ""];
  if (open.length) {
    o.push("| Id | Para el cliente | Pregunta | Bloquea |", "|---|---|---|---|");
    for (const q of open) o.push(`| ${q.id} | ${oneLine(q.client)} | ${oneLine(q.question)} | ${oneLine(q.blocks)} |`);
  } else o.push("Ninguna.");
  if (markers.length) {
    o.push("", `## Marcadores [NEEDS CLARIFICATION] en spec/ (${markers.length})`, "");
    for (const m of markers) o.push(`- \`${m.file}:${m.line}\` ${oneLine(m.text)}`);
  }
  o.push("", `## Decididas (${done.length})`, "");
  if (done.length) {
    o.push("| Id | Para el cliente | Respuesta | Aplicada |", "|---|---|---|---|");
    for (const q of done) o.push(`| ${q.id} | ${oneLine(q.client || q.question)} | ${oneLine(q.answer)} | ${oneLine(q.applied)} |`);
  } else o.push("Ninguna.");
  return o.join("\n") + "\n";
}

// ------------------------------------------------------------------ CLI
let PROG = "sdd";
class Exit extends Error { constructor(code) { super(`exit ${code}`); this.code = code; } }
function usage(msg) { console.error(`${PROG}: ${msg}`); console.error(`usage: ${PROG} questions sync | list [--open] [--json] | view [--out FILE]`); throw new Exit(2); }

export function runQuestions(argv, { prog = "sdd" } = {}) {
  PROG = prog;
  try {
    const o = { _: [], json: false, open: false, out: null, root: "." };
    for (let i = 0; i < argv.length; i++) {
      const a = argv[i];
      if (a === "--json") o.json = true;
      else if (a === "--open") o.open = true;
      else if (a === "--out") { if (i + 1 >= argv.length) usage("--out needs a value"); o.out = argv[++i]; }
      else if (a === "--repo" || a === "--dir") { if (i + 1 >= argv.length) usage(`${a} needs a value`); o.root = argv[++i]; }
      else if (a.startsWith("-")) usage(`unknown option ${a}`);
      else o._.push(a);
    }
    const sub = o._.shift();
    const root = path.resolve(o.root);
    if (sub === "sync") {
      const w = syncQuestions(root);
      if (o.json) console.log(JSON.stringify({ written: w }, null, 2));
      else console.log(w.length ? `questions: ${w.length} file(s) copied to ${MIRROR_DIR}/ (${w.join(", ")})` : `questions: ${MIRROR_DIR}/ already up to date`);
      return 0;
    }
    if (sub === "list") {
      const r = loadQuestions(root);
      const qs = o.open ? r.questions.filter((q) => q.state === "OPEN") : r.questions;
      if (o.json) console.log(JSON.stringify({ from: r.from, questions: qs }, null, 2));
      else {
        for (const q of qs) console.log(`${q.id} [${q.state}] ${q.client || q.question}${q.answer ? ` → ${q.answer}` : ""}`);
        console.log(`questions: ${qs.length} (${r.questions.filter((q) => q.state === "OPEN").length} open) from ${r.from}/`);
      }
      return 0;
    }
    if (sub === "view") {
      const md = renderView({ ...loadQuestions(root), markers: specMarkers(root) });
      if (o.out) { const abs = path.resolve(root, o.out); mkdirSync(path.dirname(abs), { recursive: true }); writeFileSync(abs, md); console.log(`questions: view written to ${o.out}`); }
      else process.stdout.write(md);
      return 0;
    }
    usage(`unknown questions command ${sub ?? "(none)"}: use sync, list or view`);
  } catch (e) {
    if (e instanceof Exit) return e.code;
    throw e;
  }
  return 0;
}

