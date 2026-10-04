import { test } from "node:test";
import assert from "node:assert/strict";
import { engineOperationIds, EXPECTED_ENGINE_OPERATIONS, bundleErrors } from "./check-engine-bundle.mjs";

const op = (operationId) => ({ operationId, responses: {} });

test("collects operation ids across methods", () => {
  const doc = { paths: { "/a": { get: op("x"), head: op("y") }, "/b": { options: op("z") } } };
  assert.deepEqual(engineOperationIds(doc), ["x", "y", "z"]);
});

test("accepts exactly the expected engine operations", () => {
  const paths = {};
  EXPECTED_ENGINE_OPERATIONS.forEach((id, i) => (paths[`/p${i}`] = { post: op(id) }));
  assert.deepEqual(bundleErrors({ paths }), []);
});

test("reports missing and unexpected operations", () => {
  const paths = {};
  EXPECTED_ENGINE_OPERATIONS.filter((id) => id !== "refreshTokens").forEach((id, i) => (paths[`/p${i}`] = { post: op(id) }));
  paths["/admin"] = { get: op("listUsers") };
  const text = bundleErrors({ paths }).join("\n");
  assert.match(text, /missing engine operation: refreshTokens/);
  assert.match(text, /unexpected engine operation: listUsers/);
});
