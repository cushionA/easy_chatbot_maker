// `npm run typecheck` entrypoint. Builds the whole TS project graph with `tsc -b`,
// driven by the references in the root tsconfig.json. Until the first package
// (apps/api, apps/web, workers, packages/*) registers itself there, it no-ops with a
// hint instead of failing on an empty solution (TS18002). No app scaffold is shipped;
// this is the wiring that activates the moment a package is added.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const root = new URL("../tsconfig.json", import.meta.url);
const config = JSON.parse(readFileSync(root, "utf8"));

if (!config.references?.length) {
  console.log(
    'typecheck: no TS packages registered yet. Add { "path": "apps/api" } to ' +
      "tsconfig.json#references when the first package lands (see docs/conventions/typescript.md).",
  );
  process.exit(0);
}

execFileSync("tsc", ["-b"], { stdio: "inherit", shell: true });
