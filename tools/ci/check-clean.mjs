// Fails when the working tree differs from HEAD, including untracked files (used after `task gen`).
import { execFileSync } from "node:child_process";

const out = execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim();
if (out) {
  console.error("Generated output differs from the committed files. Run `task gen` and commit:\n" + out);
  process.exit(1);
}
console.log("working tree clean");
