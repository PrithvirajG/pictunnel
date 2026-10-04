// Prints the trimmed contents of a version file, or a fallback when it does not exist yet.
import { readFileSync } from "node:fs";
const [file, fallback = ""] = process.argv.slice(2);
try {
  process.stdout.write(readFileSync(file, "utf8").trim());
} catch {
  process.stdout.write(fallback);
}
