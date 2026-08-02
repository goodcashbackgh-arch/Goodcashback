import crypto from "node:crypto";
import { access } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { chromium } from "@playwright/test";
import { runBrowserAcceptance } from "./20260802_hybrid_physical_receipt_browser_acceptance_v1.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const seedFile = path.join(here, "20260802_hybrid_physical_receipt_browser_fixture_seed_v1.sql");
const cleanupFile = path.join(here, "20260802_hybrid_physical_receipt_browser_fixture_cleanup_v1.sql");

const required = [
  "PHYSICAL_RECEIPT_ACCEPTANCE_DB_URL",
  "PHYSICAL_RECEIPT_ACCEPTANCE_EXPECTED_DATABASE",
  "PHYSICAL_RECEIPT_ACCEPTANCE_TEMPLATE_REVIEW_ID",
  "PLAYWRIGHT_BASE_URL",
  "IMPORTER_A_STORAGE_STATE",
  "IMPORTER_B_STORAGE_STATE",
  "SUPERVISOR_STORAGE_STATE",
  "ORDINARY_STAFF_STORAGE_STATE",
  "IMPORTER_A_AUTH_USER_ID",
  "IMPORTER_B_AUTH_USER_ID",
  "SUPERVISOR_AUTH_USER_ID",
  "ORDINARY_STAFF_AUTH_USER_ID",
];

function fail(message) {
  throw new Error(message);
}

if (process.env.PHYSICAL_RECEIPT_ACCEPTANCE_ALLOW_FIXTURES !== "true") {
  fail("PHYSICAL_RECEIPT_ACCEPTANCE_ALLOW_FIXTURES must equal true. Fixture writes are otherwise refused.");
}
for (const key of required) {
  if (!process.env[key]) fail(`${key} is required for repeatable physical-receipt browser acceptance.`);
}
for (const key of required.filter((key) => key.endsWith("STORAGE_STATE"))) {
  await access(process.env[key]);
}
await access(seedFile);
await access(cleanupFile);

function psql(script, variables) {
  const args = [
    process.env.PHYSICAL_RECEIPT_ACCEPTANCE_DB_URL,
    "--set=ON_ERROR_STOP=1",
    "--no-psqlrc",
    "--file",
    script,
  ];
  for (const [key, value] of Object.entries(variables)) {
    args.push(`--set=${key}=${String(value)}`);
  }

  const result = spawnSync("psql", args, {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) fail(`Unable to execute psql: ${result.error.message}`);
  if (result.status !== 0) {
    fail([
      `psql failed for ${path.basename(script)} with exit code ${result.status}.`,
      result.stdout?.trim(),
      result.stderr?.trim(),
    ].filter(Boolean).join("\n"));
  }
  return result.stdout.trim();
}

function parseLastJson(output, label) {
  const lines = output.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      return JSON.parse(lines[index]);
    } catch {
      // psql may emit notices before the final machine-readable row.
    }
  }
  fail(`${label} did not return a JSON object. Output:\n${output}`);
}

const runId = crypto.randomUUID();
const commonVars = {
  RUN_ID: runId,
  EXPECTED_DATABASE: process.env.PHYSICAL_RECEIPT_ACCEPTANCE_EXPECTED_DATABASE,
};
let fixture;
let primaryError;

try {
  const seedOutput = psql(seedFile, {
    ...commonVars,
    TEMPLATE_REVIEW_ID: process.env.PHYSICAL_RECEIPT_ACCEPTANCE_TEMPLATE_REVIEW_ID,
    IMPORTER_A_AUTH_USER_ID: process.env.IMPORTER_A_AUTH_USER_ID,
    IMPORTER_B_AUTH_USER_ID: process.env.IMPORTER_B_AUTH_USER_ID,
    SUPERVISOR_AUTH_USER_ID: process.env.SUPERVISOR_AUTH_USER_ID,
    ORDINARY_STAFF_AUTH_USER_ID: process.env.ORDINARY_STAFF_AUTH_USER_ID,
  });
  fixture = parseLastJson(seedOutput, "Fixture seed");
  if (fixture.run_id !== runId || !fixture.review_id || !fixture.order_id || !fixture.storage_object_path) {
    fail("Fixture seed returned an incomplete or mismatched manifest.");
  }

  await runBrowserAcceptance({
    chromium,
    baseURL: process.env.PLAYWRIGHT_BASE_URL,
    fixture,
    storageStates: {
      importerA: process.env.IMPORTER_A_STORAGE_STATE,
      importerB: process.env.IMPORTER_B_STORAGE_STATE,
      supervisor: process.env.SUPERVISOR_STORAGE_STATE,
      ordinaryStaff: process.env.ORDINARY_STAFF_STORAGE_STATE,
    },
  });
} catch (error) {
  primaryError = error;
} finally {
  if (fixture) {
    try {
      const cleanupOutput = psql(cleanupFile, {
        ...commonVars,
        ORDER_ID: fixture.order_id,
        REVIEW_ID: fixture.review_id,
        RECEIPT_ID: fixture.receipt_id,
        TRACKING_SUBMISSION_ID: fixture.tracking_submission_id,
        SUPPLIER_INVOICE_ID: fixture.supplier_invoice_id,
        SUPPLIER_INVOICE_LINE_ID: fixture.supplier_invoice_line_id,
        STORAGE_OBJECT_PATH: fixture.storage_object_path,
      });
      const cleanup = parseLastJson(cleanupOutput, "Fixture cleanup");
      if (cleanup.cleanup !== "PASS" || cleanup.run_id !== runId || cleanup.remaining_rows !== 0) {
        fail("Fixture cleanup did not prove zero run-owned remnants.");
      }
    } catch (cleanupError) {
      primaryError = primaryError
        ? new AggregateError([primaryError, cleanupError], "Browser acceptance and fixture cleanup both failed.")
        : cleanupError;
    }
  }
}

if (primaryError) throw primaryError;
console.log(`PASS — repeatable authenticated physical-receipt browser acceptance passed and cleaned run ${runId}`);
