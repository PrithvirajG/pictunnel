// Verifies the engine subset contains exactly the operations the native engines may call.
// Usage: node tools/check-engine-bundle.mjs build/engine-openapi.yaml
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parse } from "yaml";

export const EXPECTED_ENGINE_OPERATIONS = [
  "getServerInfo", "refreshTokens", "checkContent", "optionsUploads", "createUpload",
  "getUploadOffset", "appendUpload", "terminateUpload", "deleteTombstone",
];
const METHODS = ["get", "put", "post", "delete", "options", "head", "patch"];

export function engineOperationIds(doc) {
  const ids = [];
  for (const item of Object.values(doc.paths ?? {})) {
    for (const m of METHODS) if (item[m]?.operationId) ids.push(item[m].operationId);
  }
  return ids;
}

export function bundleErrors(doc) {
  const actual = new Set(engineOperationIds(doc));
  const expected = new Set(EXPECTED_ENGINE_OPERATIONS);
  return [
    ...[...expected].filter((id) => !actual.has(id)).map((id) => `missing engine operation: ${id}`),
    ...[...actual].filter((id) => !expected.has(id)).map((id) => `unexpected engine operation: ${id}`),
  ];
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2];
  const errors = bundleErrors(parse(readFileSync(file, "utf8")));
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }
  console.log(`engine bundle: ok (${EXPECTED_ENGINE_OPERATIONS.length} operations)`);
}
