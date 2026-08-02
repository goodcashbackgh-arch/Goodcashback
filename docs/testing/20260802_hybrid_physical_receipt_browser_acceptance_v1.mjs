import { access } from "node:fs/promises";

const required = [
  "PLAYWRIGHT_BASE_URL",
  "IMPORTER_A_STORAGE_STATE",
  "IMPORTER_B_STORAGE_STATE",
  "SUPERVISOR_STORAGE_STATE",
  "ORDINARY_STAFF_STORAGE_STATE",
  "PHYSICAL_REVIEW_ID",
  "PHYSICAL_EVIDENCE_FILENAME",
];
for (const key of required) {
  if (!process.env[key]) throw new Error(`${key} is required for authenticated browser acceptance.`);
}
for (const key of required.filter((key) => key.endsWith("STORAGE_STATE"))) {
  await access(process.env[key]);
}

let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  throw new Error("The Playwright package is required. Run this harness in the repository browser-test environment.");
}

const baseURL = process.env.PLAYWRIGHT_BASE_URL.replace(/\/$/, "");
const reviewId = process.env.PHYSICAL_REVIEW_ID;
const evidenceName = process.env.PHYSICAL_EVIDENCE_FILENAME;
const importerFirstNote = `Browser split proposal ${Date.now()}`;
const returnNote = `Browser return for information ${Date.now()}`;
const importerSecondNote = `Browser resubmission ${Date.now()}`;
const approvalNote = `Browser explicit supervisor approval ${Date.now()}`;

async function newContext(browser, storageState) {
  return browser.newContext({ baseURL, storageState });
}

async function expectVisible(page, text) {
  await page.getByText(text, { exact: false }).first().waitFor({ state: "visible" });
}

async function expectDenied(page, path, label) {
  const response = await page.goto(path);
  if (response?.status() === 404 || response?.status() === 403) return;
  const body = await page.textContent("body");
  if (!/not found|denied|unauthor|forbidden|login/i.test(body ?? "")) {
    throw new Error(`${label} did not fail closed.`);
  }
}

async function openEvidence(page) {
  const link = page.getByRole("link", { name: evidenceName }).first();
  await link.waitFor({ state: "visible" });
  const href = await link.getAttribute("href");
  if (!href) throw new Error("Authorised evidence link has no signed URL.");
  const response = await page.request.get(href);
  if (!response.ok()) throw new Error(`Authorised evidence URL failed with ${response.status()}.`);
}

async function prepareSplitProposal(page, note) {
  const affectedSections = page.locator("section").filter({ has: page.getByText(/affected\s+\d+/i) });
  if ((await affectedSections.count()) < 1) throw new Error("No affected disposition section is available for proposal acceptance.");

  let target = null;
  for (let index = 0; index < await affectedSections.count(); index += 1) {
    const section = affectedSections.nth(index);
    const text = await section.textContent();
    const match = text?.match(/affected\s+(\d+)/i);
    if (match && Number(match[1]) >= 2) {
      target = section;
      break;
    }
  }
  if (!target) {
    throw new Error("Browser acceptance fixture must contain one affected disposition with at least two whole units for split-proposal proof.");
  }

  const addSplit = target.getByRole("button", { name: "Add split" });
  await addSplit.click();

  const quantities = target.locator('input[type="number"]');
  const remedies = target.locator("select");
  if ((await quantities.count()) !== 2 || (await remedies.count()) !== 2) {
    throw new Error("Split proposal did not produce exactly two editable rows for the controlled fixture.");
  }

  await quantities.nth(0).fill("1.5");
  const submit = page.getByRole("button", { name: "Submit proposal" });
  if (await submit.isEnabled()) throw new Error("Fractional importer quantity left submission enabled.");

  await quantities.nth(0).fill("1");
  await quantities.nth(1).fill("1");
  await remedies.nth(0).selectOption("refund");
  await remedies.nth(1).selectOption("replacement");
  await page.getByLabel("Factual proposal note").fill(note);
  if (!(await submit.isEnabled())) throw new Error("Valid whole-unit split proposal did not enable submission.");
}

async function submitProposal(page) {
  await Promise.all([
    page.waitForURL((url) => url.pathname === `/importer/physical-receipts/${reviewId}` && url.searchParams.has("success")),
    page.getByRole("button", { name: "Submit proposal" }).click(),
  ]);
  await expectVisible(page, "Proposal submitted for supervisor review");
  await expectVisible(page, "awaiting supervisor review");
}

async function submitSupervisorDecision(page, expectedStatus) {
  await Promise.all([
    page.waitForURL((url) => url.pathname === `/internal/physical-receipts/${reviewId}` && url.searchParams.has("success")),
    page.getByRole("button", { name: "Record supervisor decision" }).click(),
  ]);
  await expectVisible(page, "Supervisor decision recorded");
  await expectVisible(page, expectedStatus);
}

const browser = await chromium.launch({ headless: true });
try {
  const importerA = await newContext(browser, process.env.IMPORTER_A_STORAGE_STATE);
  const pageA = await importerA.newPage();

  // 1. Importer badge, action queue, exact detail and authorised evidence.
  await pageA.goto("/importer");
  await expectVisible(pageA, "Physical Receipt Exceptions");
  const importerBadgeText = await pageA.getByRole("link", { name: /Physical Receipt Exceptions/i }).textContent();
  if (!/\d+/.test(importerBadgeText ?? "")) throw new Error("Importer action entry has no numeric badge.");
  await pageA.goto("/importer/physical-receipts");
  await expectVisible(pageA, "Affected receipts currently requiring importer action");
  await pageA.goto(`/importer/physical-receipts/${reviewId}`);
  await expectVisible(pageA, "Immutable receipt facts");
  await openEvidence(pageA);

  // 2. Cross-importer direct detail denial before mutation.
  const importerB = await newContext(browser, process.env.IMPORTER_B_STORAGE_STATE);
  const pageB = await importerB.newPage();
  await expectDenied(pageB, `/importer/physical-receipts/${reviewId}`, "Cross-importer direct review access");
  await importerB.close();

  // 3. Real whole-unit split submission through importer v2.
  await prepareSplitProposal(pageA, importerFirstNote);
  await submitProposal(pageA);

  // 4. Supervisor badge, exact proposal rows, explicit return-for-information.
  const supervisor = await newContext(browser, process.env.SUPERVISOR_STORAGE_STATE);
  const pageS = await supervisor.newPage();
  await pageS.goto("/internal");
  await expectVisible(pageS, "Physical Receipt Reviews");
  const supervisorBadgeText = await pageS.getByRole("link", { name: /Physical Receipt Reviews/i }).textContent();
  if (!/\d+/.test(supervisorBadgeText ?? "")) throw new Error("Supervisor action entry has no numeric badge.");
  await pageS.goto(`/internal/physical-receipts/${reviewId}`);
  await expectVisible(pageS, "Importer proposal");
  await expectVisible(pageS, "Proposed refund");
  await expectVisible(pageS, "Proposed replacement");
  await openEvidence(pageS);

  const decision = pageS.locator('select[name="decision"]');
  await decision.selectOption("return_for_information");
  if (await pageS.locator('input[name="allocations_json"]').inputValue() !== "[]") {
    throw new Error("Return-for-information carried supervisor allocations.");
  }
  await pageS.getByLabel("Decision note").fill(returnNote);
  await submitSupervisorDecision(pageS, "returned for information");

  // 5. Same review ID reopens for importer and supports resubmission.
  await pageA.goto(`/importer/physical-receipts/${reviewId}`);
  await expectVisible(pageA, "Returned for information");
  await expectVisible(pageA, returnNote);
  await prepareSplitProposal(pageA, importerSecondNote);
  await submitProposal(pageA);

  // 6. Explicit compatible supervisor approval, no silent conversion.
  await pageS.goto(`/internal/physical-receipts/${reviewId}`);
  await expectVisible(pageS, "Proposed refund");
  await expectVisible(pageS, "Proposed replacement");
  const existingOption = decision.locator('option[value="approve_existing_exception"]');
  if (await existingOption.isDisabled()) throw new Error("Compatible refund/replacement proposal incorrectly disabled existing-exception approval.");
  await decision.selectOption("approve_existing_exception");

  const allocationPayload = JSON.parse(await pageS.locator('input[name="allocations_json"]').inputValue());
  if (!Array.isArray(allocationPayload) || allocationPayload.length !== 2) throw new Error("Supervisor approval does not cover both importer proposal rows.");
  const approvedTypes = allocationPayload.map((row) => row.approved_remedy_type).sort();
  if (approvedTypes.join(",") !== "refund,replacement") throw new Error("Supervisor form silently converted importer remedy types.");

  await pageS.getByLabel("Decision note").fill(approvalNote);
  await submitSupervisorDecision(pageS, "approved to existing exception");

  // 7. Every outcome-specific linked dispute is displayed and navigable.
  await expectVisible(pageS, "Linked disputes");
  const linkedDisputes = pageS.locator('a[href^="/internal/exceptions/"]');
  if ((await linkedDisputes.count()) !== 2) throw new Error("Expected exactly two linked outcome-specific disputes.");
  for (let index = 0; index < await linkedDisputes.count(); index += 1) {
    const href = await linkedDisputes.nth(index).getAttribute("href");
    if (!href) throw new Error("Linked dispute has no route.");
    const verify = await supervisor.newPage();
    const response = await verify.goto(href);
    if (!response || response.status() >= 400) throw new Error(`Linked dispute route failed: ${href}`);
    await verify.close();
  }

  // 8. Ordinary staff direct supervisor detail denial.
  const ordinary = await newContext(browser, process.env.ORDINARY_STAFF_STORAGE_STATE);
  const pageO = await ordinary.newPage();
  await expectDenied(pageO, `/internal/physical-receipts/${reviewId}`, "Ordinary staff direct supervisor access");
  await ordinary.close();

  await supervisor.close();
  await importerA.close();

  console.log("PASS — authenticated physical receipt lifecycle browser acceptance passed");
} finally {
  await browser.close();
}
