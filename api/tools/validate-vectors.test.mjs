import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { compileSchema, semanticErrors, duplicateNameErrors, minimumErrors } from "./validate-vectors.mjs";

const schema = JSON.parse(readFileSync(new URL("../protocol/vectors/vectors.schema.json", import.meta.url), "utf8"));
const validate = compileSchema(schema);
const SHA = "a".repeat(64);
const hashingDoc = (cases) => ({ schema_version: 1, kind: "hashing", description: "d", cases });
const exists = () => true;

test("accepts a valid hashing file", () => {
  const doc = hashingDoc([{ name: "empty", input: { generate: { pattern: "counter", length: 0 } }, expected_sha256: SHA }]);
  assert.deepEqual(validate(doc), []);
  assert.deepEqual(semanticErrors(doc, { dirKind: "hashing", fileExists: exists }), []);
});

test("rejects a malformed sha256", () => {
  const doc = hashingDoc([{ name: "bad", input: { inline_utf8: "abc" }, expected_sha256: "ABC" }]);
  assert.notDeepEqual(validate(doc), []);
});

test("rejects a kind that does not match its directory", () => {
  const doc = hashingDoc([{ name: "x", input: { inline_utf8: "" }, expected_sha256: SHA }]);
  assert.match(semanticErrors(doc, { dirKind: "pairing", fileExists: exists }).join("\n"), /kind "hashing" in pairing\//);
});

test("rejects a missing fixture file", () => {
  const doc = hashingDoc([{ name: "jpg", input: { file: "fixtures/none.jpg" }, expected_sha256: SHA }]);
  assert.match(semanticErrors(doc, { dirKind: "hashing", fileExists: () => false }).join("\n"), /fixtures\/none\.jpg does not exist/);
});

test("rejects duplicate case names within a kind", () => {
  const a = hashingDoc([{ name: "same", input: { inline_utf8: "" }, expected_sha256: SHA }]);
  const b = hashingDoc([{ name: "same", input: { inline_utf8: "x" }, expected_sha256: SHA }]);
  assert.match(duplicateNameErrors([a, b]).join("\n"), /duplicate hashing case "same"/);
});

test("rejects server-scenario steps that use undeclared actors", () => {
  const doc = {
    schema_version: 1, kind: "server-scenario", description: "d",
    cases: [{
      name: "s", actors: { device_a: { user: "alice" } },
      steps: [{ actor: "device_b", request: { method: "GET", path: "/api/v1/server/info" }, expect: { status: 200 } }],
    }],
  };
  assert.deepEqual(validate(doc), []);
  assert.match(semanticErrors(doc, { dirKind: "server-scenario", fileExists: exists }).join("\n"), /undeclared actor "device_b"/);
});

test("rejects an expectation with both status and no_response", () => {
  const doc = {
    schema_version: 1, kind: "server-scenario", description: "d",
    cases: [{ name: "s", actors: { a: { user: "u" } }, steps: [{ actor: "a", request: { method: "GET", path: "/x" }, expect: { status: 200, no_response: true } }] }],
  };
  assert.notDeepEqual(validate(doc), []);
});

test("rejects a client decision problem shorthand without a status", () => {
  const doc = {
    schema_version: 1, kind: "client-decision", description: "d",
    cases: [{ name: "c", given: { flow: "backup", last_action: "check" }, server: { transport: "timeout", problem: "internal" }, expect: { action: "backoff_retry" } }],
  };
  assert.match(semanticErrors(doc, { dirKind: "client-decision", fileExists: exists }).join("\n"), /problem requires status/);
});

test("reports kinds below their minimum case count", () => {
  const errors = minimumErrors({ hashing: 8, pairing: 3, "server-scenario": 14, "client-decision": 25 });
  assert.equal(errors.length, 1);
  assert.match(errors[0], /pairing: 3 cases, minimum 8/);
});
