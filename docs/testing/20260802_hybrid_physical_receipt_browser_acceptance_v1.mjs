import { access } from "node:fs/promises";

const required = [
  "PLAYWRIGHT_BASE_URL",
  "IMPORTER_A_STORAGE_STATE",
  "IMPORTER_B_STORAGE_STATE",
  "SUPERVISOR_STORAGE_STATE",
  "ORDINARY_STAFF_STORAGE_STATE",
  "PHYSICAL_REVIEW_ID",
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

async function context(browser, storageState) {
  return browser.newContext({ baseURL, storageState });
}

async function expectVisible(page, text) {
  await page.getByText(text, { exact: false }).first().waitFor({ state: "visible" });
}

const browser = await chromium.launch({ headless: true });
try {
  // Importer A: badge, action queue, exact review, evidence and whole-unit split.
  const importerA = await context(browser, process.env.IMPORTER_A_STORAGE_STATE);
  const pageA = await importerA.newPage();
  await pageA.goto("/importer");
  await expectVisible(pageA, "Physical Receipt Exceptions");
  await pageA.goto(`/importer/physical-receipts/${reviewId}`);
  await expectVisible(pageA, "Immutable receipt facts");
  if (evidenceName) await expectVisible(pageA, evidenceName);
  const quantityInputs = pageA.locator('input[type="number"]');
  if (await quantityInputs.count()) {
    await quantityInputs.first().fill("1.5");
    const submit = pageA.getByRole("button", { name: "Submit proposal" });
    if (await submit.isEnabled()) throw new Error("Fractional importer quantity left submit enabled.");
    await quantityInputs.first().fill("1");
  }
  await importerA.close();

  // Importer B: direct cross-tenant detail must fail closed.
  const importerB = await context(browser, process.env.IMPORTER_B_STORAGE_STATE);
  const pageB = await importerB.newPage();
  const responseB = await pageB.goto(`/importer/physical-receipts/${reviewId}`);
  if (responseB?.status() !== 404) {
    const body = await pageB.textContent("body");
    if (!/not found|denied|unauthor/i.test(body ?? "")) throw new Error("Cross-importer direct review access did not fail closed.");
  }
  await importerB.close();

  // Supervisor: queue, exact proposal display, no silent conversion, explicit return path.
  const supervisor = await context(browser, process.env.SUPERVISOR_STORAGE_STATE);
  const pageS = await supervisor.newPage();
  await pageS.goto("/internal");
  await expectVisible(pageS, "Physical Receipt Reviews");
  await pageS.goto(`/internal/physical-receipts/${reviewId}`);
  await expectVisible(pageS, "Importer proposal");
  const decision = pageS.locator('select[name="decision"]');
  if (await decision.count()) {
    const existingOption = decision.locator('option[value="approve_existing_exception"]');
    const optionDisabled = await existingOption.isDisabled().catch(() => false);
    const warningVisible = await pageS.getByText("Approve existing exception is unavailable", { exact: false }).isVisible().catch(() => false);
    if (optionDisabled && !warningVisible) throw new Error("Disabled existing-exception decision lacks explicit explanation.");
    await decision.selectOption("return_for_information");
    const allocationPayload = await pageS.locator('input[name="allocations_json"]').inputValue();
    if (allocationPayload !== "[]") throw new Error("Return-for-information still carries supervisor allocations.");
  }
  await supervisor.close();

  // Ordinary staff: direct supervisor detail must fail closed.
  const ordinary = await context(browser, process.env.ORDINARY_STAFF_STORAGE_STATE);
  const pageO = await ordinary.newPage();
  const responseO = await pageO.goto(`/internal/physical-receipts/${reviewId}`);
  if (responseO?.status() !== 404) {
    const body = await pageO.textContent("body");
    if (!/not found|denied|unauthor|login/i.test(body ?? "")) throw new Error("Ordinary staff direct supervisor access did not fail closed.");
  }
  await ordinary.close();

  console.log("PASS — authenticated physical receipt browser acceptance checks passed");
} finally {
  await browser.close();
}
