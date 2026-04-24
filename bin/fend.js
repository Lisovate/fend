#!/usr/bin/env node
// Thin platform-detect wrapper. The real binary lives in a per-platform
// optional dependency (e.g. @fendsh/cli-darwin-arm64). npm only installs the
// optional dep that matches the user's os/cpu, so the wrapper just has to
// locate it and exec.

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const target = `${process.platform}-${process.arch}`;
const SUPPORTED = ["darwin-arm64"];

if (!SUPPORTED.includes(target)) {
  console.error(`fend: ${target} is not yet supported.`);
  console.error(`Supported: ${SUPPORTED.join(", ")}`);
  console.error(`Roadmap: https://github.com/Lisovate/fend`);
  process.exit(1);
}

const pkg = `@fendsh/cli-${target}`;

function findBinary() {
  // Production: the optional dep landed in node_modules. Resolve via its
  // package.json so we don't depend on Node honoring `exports` for raw files.
  try {
    const root = path.dirname(require.resolve(`${pkg}/package.json`));
    const p = path.join(root, "bin", "fend");
    if (fs.existsSync(p)) return p;
  } catch {}

  // Local dev / monorepo: platform package is a sibling directory.
  const dev = path.resolve(
    __dirname, "..", "packages", `cli-${target}`, "bin", "fend"
  );
  if (fs.existsSync(dev)) return dev;

  return null;
}

const binary = findBinary();
if (!binary) {
  console.error(`fend: native binary for ${target} is missing.`);
  console.error(`If you installed via npm, optional deps may have been skipped:`);
  console.error(`  npm install ${pkg}`);
  process.exit(1);
}

const child = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (child.error) {
  console.error(`fend: ${child.error.message}`);
  process.exit(1);
}
process.exit(child.status ?? 1);
