// evidence-manifest.mjs — acceptance/evidence-manifest-<FASE-N|all>.json, written by `sdd accept --report`.
// Node >= 18, no dependencies. Library: no console output, no process.exit.
//
// The evidence dir (`evidencias/`) is git-ignored, so the versioned report links files that do not travel with the
// tag (club, 11/2026). The manifest is versioned next to the report: path, sha256, bytes and kind of every capture and
// video the acceptance used, and the criteria each one backs. A clone of the tag cannot show the images, but it proves
// which ones were seen: anyone holding `sdd accept pack`'s archive (or the original folder) can check them by hash.
//
// Content: the in-scope criteria's evidence attachments that are present (from the ledger just written), plus every
// file under {evidence_dir}/FASE-N/ (all of the evidence dir without --fase). Sorted, without timestamps: running the
// acceptance twice on the same evidence rewrites the same bytes, so it never dirties the tree for nothing.
import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { describeFile, evidenceSettings } from "./acceptance.mjs";

export const MANIFEST_SCHEMA = "sdd-evidence-manifest-v1";
export const manifestPath = (fase) => `acceptance/evidence-manifest-${fase === undefined || fase === null ? "all" : `FASE-${fase}`}.json`;

function filesUnder(dir) {
  const acc = [];
  let es = [];
  try { es = readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of es) {
    if (e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) acc.push(...filesUnder(p)); else if (e.isFile()) acc.push(p);
  }
  return acc;
}

/** The manifest object, or null when there is no evidence at all. ledger: the JSON `sdd accept` wrote (optional). */
export function buildManifest(root, { fase, ledger = null } = {}) {
  const { dir } = evidenceSettings(root);
  const byPath = new Map();
  const cache = new Map();
  const add = (abs, criterion) => {
    const d = describeFile(root, abs, cache);
    if (!d.present) return;
    if (!byPath.has(d.path)) byPath.set(d.path, { path: d.path, sha256: d.sha256, bytes: d.bytes, kind: d.kind, criteria: new Set() });
    if (criterion) byPath.get(d.path).criteria.add(criterion);
  };
  for (const r of ledger?.requirements || []) {
    if (r.in_scope === false) continue;
    for (const c of r.criteria || []) for (const e of c.evidence || []) for (const a of e.attachments || []) {
      if (!a || !a.path || !["image", "video"].includes(a.kind)) continue;
      add(path.resolve(root, a.path), `${r.id} AC${c.n ?? c.index}`);
    }
  }
  const base = path.join(root, dir, ...(fase === undefined || fase === null ? [] : [`FASE-${fase}`]));
  if (existsSync(base) && statSync(base).isDirectory()) for (const f of filesUnder(base)) add(f, null);
  if (!byPath.size) return null;
  const files = [...byPath.values()].sort((a, b) => a.path.localeCompare(b.path))
    .map((f) => ({ ...f, criteria: [...f.criteria].sort() }));
  return {
    $schema: MANIFEST_SCHEMA, fase: fase ?? null, evaluated_sha: ledger?.evaluated_sha ?? null, dirty: ledger?.dirty ?? null,
    evidence_dir: dir, note: `${dir}/ is not versioned: this manifest proves which files were seen (sha256); sdd accept pack bundles them`,
    files,
  };
}

/** Writes the manifest when it changed; returns its relative path, or null when there was nothing to write. */
export function writeManifest(root, opts = {}) {
  const m = buildManifest(root, opts);
  if (!m) return null;
  const rel = manifestPath(opts.fase);
  const abs = path.join(root, rel);
  const text = JSON.stringify(m, null, 2) + "\n";
  let prev = null;
  try { prev = readFileSync(abs, "utf8"); } catch { /* new */ }
  if (prev !== text) { mkdirSync(path.dirname(abs), { recursive: true }); writeFileSync(abs, text); }
  return rel;
}
