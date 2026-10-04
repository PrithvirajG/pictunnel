// Ensures sync-protocol.md has a worked-example heading (#### `operationId`) for every operation.
// Usage: node tools/check-protocol-doc.mjs openapi.yaml protocol/sync-protocol.md
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parse } from "yaml";
import { engineOperationIds as allOperationIds } from "./check-engine-bundle.mjs";

export function missingExamples(operationIds, markdown) {
  return operationIds.filter((id) => !new RegExp("^#### `" + id + "`\s*$", "m").test(markdown));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [specFile, docFile] = process.argv.slice(2);
  const ids = allOperationIds(parse(readFileSync(specFile, "utf8")));
  const missing = missingExamples(ids, readFileSync(docFile, "utf8"));
  if (missing.length) {
    console.error(`${docFile} lacks worked examples for:\n` + missing.join("\n"));
    process.exit(1);
  }
  console.log(`protocol doc: ok (${ids.length} operations have examples)`);
}
