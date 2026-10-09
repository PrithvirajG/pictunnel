import { test } from "node:test";
import assert from "node:assert/strict";
import { missingExamples } from "./check-protocol-doc.mjs";

test("reports operations without a worked example heading", () => {
  const md = "#### `getServerInfo`\n\n```http\nGET /api/v1/server/info\n```\n\n#### `checkContent`\n";
  assert.deepEqual(missingExamples(["getServerInfo", "checkContent", "createUpload"], md), ["createUpload"]);
});

test("a mention in prose is not an example", () => {
  assert.deepEqual(missingExamples(["login"], "Call `login` first."), ["login"]);
});

test("accepts trailing spaces and CRLF after a heading", () => {
  assert.deepEqual(missingExamples(["getServerInfo"], "#### `getServerInfo`  \r\n"), []);
});

test("rejects a heading that only shares an id prefix", () => {
  assert.deepEqual(missingExamples(["getServerInfo"], "#### `getServerInfoX`\n"), ["getServerInfo"]);
});
