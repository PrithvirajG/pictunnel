import { test } from "node:test";
import assert from "node:assert/strict";
import { missingSignoff } from "./check-dco.mjs";

test("passes signed-off commits", () => {
  const commits = [{ sha: "a1", body: "feat: x\n\nSigned-off-by: Jane Doe <jane@example.com>\n" }];
  assert.deepEqual(missingSignoff(commits), []);
});

test("reports commits without sign-off", () => {
  const commits = [
    { sha: "a1", body: "feat: x\n\nSigned-off-by: Jane Doe <jane@example.com>" },
    { sha: "b2", body: "fix: y\n\nCo-Authored-By: Someone <s@example.com>" },
  ];
  assert.deepEqual(missingSignoff(commits), ["b2"]);
});

test("rejects a sign-off without an email", () => {
  assert.deepEqual(missingSignoff([{ sha: "c3", body: "x\n\nSigned-off-by: Jane" }]), ["c3"]);
});
