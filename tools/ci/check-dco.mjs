// Usage: node tools/ci/check-dco.mjs <base-ref> <head-ref>
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const SIGNOFF = /^Signed-off-by: .+ <[^<>\s]+@[^<>\s]+>\s*$/m;

export function missingSignoff(commits) {
  return commits.filter((c) => !SIGNOFF.test(c.body)).map((c) => c.sha);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [base, head] = process.argv.slice(2);
  if (!base || !head) {
    console.error("usage: check-dco.mjs <base> <head>");
    process.exit(2);
  }
  const raw = execFileSync("git", ["log", "--no-merges", "--format=%H%x00%B%x1e", `${base}..${head}`], { encoding: "utf8" });
  const commits = raw.split("\x1e").map((r) => r.trim()).filter(Boolean).map((r) => {
    const [sha, body] = r.split("\0");
    return { sha, body };
  });
  const bad = missingSignoff(commits);
  if (bad.length) {
    console.error("Commits missing a DCO sign-off (use git commit -s):\n" + bad.join("\n"));
    process.exit(1);
  }
  console.log(`dco: ${commits.length} commit(s) signed off`);
}
