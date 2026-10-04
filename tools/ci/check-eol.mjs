// Fails when a text file is stored in the git index with CRLF or mixed line endings.
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const WINDOWS_SCRIPT = /\.(bat|cmd|ps1)$/i;

export function crlfViolations(eolOutput) {
  const bad = [];
  for (const entry of eolOutput.split("\0")) {
    if (!entry.trim()) continue;
    const tab = entry.indexOf("\t");
    const meta = entry.slice(0, tab);
    const path = entry.slice(tab + 1);
    const index = meta.trim().split(/\s+/)[0];
    if ((index === "i/crlf" || index === "i/mixed") && !WINDOWS_SCRIPT.test(path)) bad.push(path);
  }
  return bad;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const out = execFileSync("git", ["ls-files", "--eol", "-z"], { encoding: "utf8" });
  const bad = crlfViolations(out);
  if (bad.length) {
    console.error("Files with CRLF/mixed line endings in the index:\n" + bad.join("\n"));
    process.exit(1);
  }
  console.log("eol: ok");
}
