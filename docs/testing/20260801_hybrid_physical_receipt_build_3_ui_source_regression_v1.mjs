import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const BASE_REF = process.env.BASE_REF || "origin/main";

function fail(message) {
  console.error(`FAIL — ${message}`);
  process.exit(1);
}

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

const impact