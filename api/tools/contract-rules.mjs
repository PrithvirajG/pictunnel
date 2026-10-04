// Project-specific contract rules that Redocly does not cover.
// Usage: node tools/contract-rules.mjs openapi.yaml
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parse } from "yaml";

const SNAKE = /^[a-z][a-z0-9]*(_[a-z0-9]+)*$/;
const ALLOWED_TAGS = new Set(["server", "auth", "pairing", "devices", "sync", "uploads", "assets", "engine"]);
const METHODS = ["get", "put", "post", "delete", "options", "head", "patch"];
const NO_BODY = new Set(["head", "options"]);
const HEALTH = new Set(["/healthz", "/readyz"]);

function deref(doc, node) {
  let cur = node;
  for (let i = 0; cur && typeof cur.$ref === "string"; i++) {
    if (i > 20) throw new Error(`$ref cycle at ${node.$ref}`);
    if (!cur.$ref.startsWith("#/")) throw new Error(`external $ref not allowed: ${cur.$ref}`);
    cur = cur.$ref
      .slice(2)
      .split("/")
      .reduce((o, k) => o?.[k.replaceAll("~1", "/").replaceAll("~0", "~")], doc);
  }
  return cur;
}

function children(schema) {
  const out = [];
  for (const [name, sub] of Object.entries(schema.properties ?? {})) out.push([`.${name}`, sub]);
  for (const key of ["items", "additionalProperties", "not"]) {
    if (schema[key] && typeof schema[key] === "object") out.push([`.${key}`, schema[key]]);
  }
  for (const key of ["allOf", "oneOf", "anyOf"]) (schema[key] ?? []).forEach((s, i) => out.push([`.${key}[${i}]`, s]));
  return out;
}

// Property naming and $ref siblings. Does not follow $refs: components are checked on their own.
function checkNaming(schema, where, errors) {
  if (!schema || typeof schema !== "object") return;
  if (schema.$ref) {
    if (Object.keys(schema).length > 1) errors.push(`${where}: sibling keys next to $ref are ignored in OpenAPI 3.0`);
    return;
  }
  for (const name of Object.keys(schema.properties ?? {})) {
    if (!SNAKE.test(name)) errors.push(`${where}: property "${name}" is not snake_case`);
  }
  for (const [suffix, sub] of children(schema)) checkNaming(sub, where + suffix, errors);
}

// Follows $refs from response bodies and flags closed enums: clients must tolerate new values.
function checkResponseEnums(doc, schema, where, errors, seen) {
  if (!schema || typeof schema !== "object") return;
  const resolved = deref(doc, schema);
  if (!resolved || seen.has(resolved)) return;
  seen.add(resolved);
  if (Array.isArray(resolved.enum)) errors.push(`${where}: closed enum reachable from a response (use type: string + x-known-values)`);
  for (const [suffix, sub] of children(resolved)) checkResponseEnums(doc, sub, where + suffix, errors, seen);
}

export function checkContract(doc) {
  const errors = [];
  if (doc.openapi !== "3.0.3") errors.push(`openapi must be "3.0.3", found "${doc.openapi}"`);
  for (const [name, schema] of Object.entries(doc.components?.schemas ?? {})) {
    checkNaming(schema, `components.schemas.${name}`, errors);
  }
  const enumSeen = new Set();
  for (const [path, item] of Object.entries(doc.paths ?? {})) {
    if (!path.startsWith("/api/v1/") && !HEALTH.has(path)) errors.push(`${path}: must start with /api/v1/`);
    for (const method of METHODS) {
      const op = item[method];
      if (!op) continue;
      const id = `${method.toUpperCase()} ${path}`;
      if (!op.operationId) errors.push(`${id}: missing operationId`);
      if (!op.tags?.length) errors.push(`${id}: missing tags`);
      for (const tag of op.tags ?? []) if (!ALLOWED_TAGS.has(tag)) errors.push(`${id}: unknown tag "${tag}"`);
      for (const param of [...(item.parameters ?? []), ...(op.parameters ?? [])].map((p) => deref(doc, p))) {
        if ((param.in === "query" || param.in === "path") && !SNAKE.test(param.name)) {
          errors.push(`${id}: parameter "${param.name}" is not snake_case`);
        }
      }
      const body = deref(doc, op.requestBody);
      for (const media of Object.values(body?.content ?? {})) checkNaming(media.schema, `${id} requestBody`, errors);
      let hasProblem = false;
      for (const [status, ref] of Object.entries(op.responses ?? {})) {
        const res = deref(doc, ref);
        for (const [type, media] of Object.entries(res?.content ?? {})) {
          checkNaming(media.schema, `${id} ${status}`, errors);
          checkResponseEnums(doc, media.schema, `${id} ${status}`, errors, enumSeen);
          if (/^[45]/.test(status) && type === "application/problem+json") hasProblem = true;
        }
      }
      if (!NO_BODY.has(method) && !hasProblem) errors.push(`${id}: no 4xx/5xx application/problem+json response`);
    }
  }
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2] ?? "openapi.yaml";
  const errors = checkContract(parse(readFileSync(file, "utf8")));
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }
  console.log(`contract rules: ok (${file})`);
}
