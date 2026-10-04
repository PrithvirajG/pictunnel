import { test } from "node:test";
import assert from "node:assert/strict";
import { crlfViolations } from "./check-eol.mjs";

test("accepts LF text files and binaries", () => {
  const out = "i/lf    w/lf    attr/text=auto eol=lf \tREADME.md\0i/-text w/-text attr/binary \tfixtures/a.jpg\0";
  assert.deepEqual(crlfViolations(out), []);
});

test("flags CRLF text files in the index", () => {
  const out = "i/crlf  w/crlf  attr/text=auto eol=lf \tserver/main.go\0";
  assert.deepEqual(crlfViolations(out), ["server/main.go"]);
});

test("allows CRLF for Windows scripts", () => {
  const out = "i/crlf  w/crlf  attr/text eol=crlf    \tmobile/android/engine-api/gradlew.bat\0";
  assert.deepEqual(crlfViolations(out), []);
});

test("flags mixed line endings", () => {
  const out = "i/mixed w/mixed attr/                 \tnotes.txt\0";
  assert.deepEqual(crlfViolations(out), ["notes.txt"]);
});
