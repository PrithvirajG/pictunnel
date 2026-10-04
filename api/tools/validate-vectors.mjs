// Validates every conformance vector file against the schema plus semantic rules.
// Usage: node api/tools/validate-vectors.mjs [--strict]   (--strict also enforces minimum case counts)
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

export const MINIMUMS = { hashing: 8, "server-scenario": 14, "client-decision": 25, pairing: 8 };
export const DIR_KIND = { hashing: "hashing", pairing: "pairing", "server-scenarios": "server-scenario", "client-decisions": "client-decision" };

export function compileSchema(schema) {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const check = ajv.compile(schema);
  return (doc) => (check(doc) ? [] : check.errors.map((e) => `${e.instancePath || "/"} ${e.message}`));
}

export function semanticErrors(doc, { dirKind, fileExists }) {
  const errors = [];
  if (doc.kind !== dirKind) errors.push(`kind "${doc.kind}" in ${dirKind}/ directory`);
  for (const c of doc.cases ?? []) {
    if (doc.kind === "hashing" && c.input?.file && !fileExists(c.input.file)) {
      errors.push(`${c.name}: ${c.input.file} does not exist`);
    }
    if (doc.kind === "server-scenario") {
      const actors = new Set(Object.keys(c.actors ?? {}));
      for (const step of c.steps ?? []) {
        if (step.actor && !actors.has(step.actor)) errors.push(`${c.name}: undeclared actor "${step.actor}"`);
        for (const src of step.control?.assert_asset_sources?.sources ?? []) {
          if (!actors.has(src.actor)) errors.push(`${c.name}: undeclared actor "${src.actor}"`);
        }
      }
    }
    if (doc.kind === "client-decision" && c.server?.problem && c.server.status === undefined) {
      errors.push(`${c.name}: problem requires status`);
    }
  }
  return errors;
}

export function duplicateNameErrors(docs) {
  const seen = new Set();
  const errors = [];
  for (const doc of docs) {
    for (const c of doc.cases ?? []) {
      const key = `${doc.kind}/${c.name}`;
      if (seen.has(key)) errors.push(`duplicate ${doc.kind} case "${c.name}"`);
      seen.add(key);
    }
  }
  return errors;
}

export function minimumErrors(counts) {
  return Object.entries(MINIMUMS)
    .filter(([kind, min]) => (counts[kind] ?? 0) < min)
    .map(([kind, min]) => `${kind}: ${counts[kind] ?? 0} cases, minimum ${min}`);
}

export function validateAll(protocolDir, { strict }) {
  const schema = JSON.parse(readFileSync(join(protocolDir, "vectors", "vectors.schema.json"), "utf8"));
  const validate = compileSchema(schema);
  const errors = [];
  const docs = [];
  const counts = {};
  for (const [dir, kind] of Object.entries(DIR_KIND)) {
    const full = join(protocolDir, "vectors", dir);
    if (!existsSync(full)) continue;
    for (const file of readdirSync(full).filter((f) => f.endsWith(".json")).sort()) {
      const rel = `${dir}/${file}`;
      let doc;
      try {
        doc = JSON.parse(readFileSync(join(full, file), "utf8"));
      } catch (e) {
        errors.push(`${rel}: invalid JSON (${e.message})`);
        continue;
      }
      const fileExists = (p) => existsSync(join(protocolDir, p));
      for (const e of [...validate(doc), ...semanticErrors(doc, { dirKind: kind, fileExists })]) errors.push(`${rel}: ${e}`);
      docs.push(doc);
      counts[kind] = (counts[kind] ?? 0) + (doc.cases?.length ?? 0);
    }
  }
  errors.push(...duplicateNameErrors(docs));
  if (strict) errors.push(...minimumErrors(counts));
  return { errors, counts };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const protocolDir = fileURLToPath(new URL("../protocol", import.meta.url));
  const { errors, counts } = validateAll(protocolDir, { strict: process.argv.includes("--strict") });
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }
  console.log("vectors: ok", JSON.stringify(counts));
}
