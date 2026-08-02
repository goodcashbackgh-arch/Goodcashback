function requireValue(value, label) {
  if (!value) throw new Error(`${label} is required for authenticated browser acceptance.`);
  return value;
}

async function newContext(browser, baseURL, storageState) {
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

async function openEvidence(page, evidenceName) {
  const link = page.getByRole("link", { name: evidenceName }).first();
  await link.waitFor({ state: "visible" });
  const href = await link.getAttribute("href");
  if (!href) throw new Error("Authorised evidence link has no signed URL.");
  const response = await page.request.get(href);
  if (!response.ok()) throw new Error(`Authorised evidence URL failed with ${response.status()}.`);
}

function parsePositiveBadge(text, label) {
  const values = (text ?? "").match(/\d+/g)?.map(Number) ?? [];
  if (!values.some((value) => value > 0)) {
    throw new Error(`${label} did not show a positive actionable count.`);
  }
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
  if (!target) throw new Error("Disposable fixture must contain one affected disposition of two whole units.");

  await target.getByRole("button", { name: "Add split" }).click();
  const quantities = target.locator('input[type="number"]');
  const remedies = target.locator("select");
  if ((await quantities.count()) !== 2 || (await remedies.count()) !== 2) {
    throw new Error("Split proposal did not produce exactly two editable rows.");
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

async function submitProposal(page, reviewId) {
  await Promise.all([
    page.waitForURL((url) => url.pathname === `/importer/physical-receipts/${reviewId}` && url.searchParams.has("success")),
    page.getByRole("button", { name: "Submit proposal" }).click(),
  ]);
  await expectVisible(page, "Proposal submitted for supervisor review");
  await expectVisible(page, "awaiting supervisor review");
}

async function submitSupervisorDecision(page, reviewId, expectedStatus) {
  await Promise.all([
    page.waitForURL((url) => url.pathname === `/internal/physical-receipts/${reviewId}` && url.searchParams.has("success")),
    page.getByRole("button", { name: "Record supervisor decision" }).click(),
  ]);
  await expectVisible(page, "Supervisor decision recorded");
  await expectVisible(page, expectedStatus);
}

async function assertImporterQueue(page, reviewId) {
  await page.goto("/importer/physical-receipts");
  await expectVisible(page, "Affected receipts currently requiring importer action");
  const cards = page.locator('a[href^="/importer/physical-receipts/"]');
  const cardCount = await cards.count();
  if (cardCount === 0) throw new Error("Importer queue rendered no review cards.");
  const target = page.locator(`a[href="/importer/physical-receipts/${reviewId}"]`);
  if ((await target.count()) === 0) throw new Error("Importer queue is missing the controlled review link.");
  const allowedStatuses = new Set(["awaiting importer proposal", "returned for information"]);
  for (let index = 0; index < cardCount; index += 1) {
    const badge = cards.nth(index).locator("span.rounded-full.bg-amber-100.px-3.py-1.text-xs.font-semibold.text-amber-800");
    const badgeCount = await badge.count();
    if (badgeCount !== 1) {
      throw new Error(`Importer queue card ${index + 1} has ${badgeCount} dedicated status badges; expected exactly one.`);
    }
    const status = ((await badge.textContent()) ?? "").trim().toLowerCase();
    if (!allowedStatuses.has(status)) {
      throw new Error(`Importer queue card ${index + 1} has status "${status}", outside the exact actionable whitelist.`);
    }
  }
}

async function assertSupervisorQueue(page, reviewId) {
  await page.goto("/internal/physical-receipts");
  const cards = page.locator('a[href^="/internal/physical-receipts/"]');
  const cardCount = await cards.count();
  if (cardCount === 0) throw new Error("Supervisor queue rendered no review cards.");
  const target = page.locator(`a[href="/internal/physical-receipts/${reviewId}"]`);
  if ((await target.count()) === 0) throw new Error("Supervisor queue is missing the controlled review link.");
  for (let index = 0; index < cardCount; index += 1) {
    const badge = cards.nth(index).locator("span.rounded-full.bg-amber-100.px-3.py-1.text-xs.font-semibold.text-amber-800");
    const badgeCount = await badge.count();
    if (badgeCount !== 1) {
      throw new Error(`Supervisor queue card ${index + 1} has ${badgeCount} dedicated status badges; expected exactly one.`);
    }
    const status = ((await badge.textContent()) ?? "").trim().toLowerCase();
    if (status !== "awaiting supervisor review") {
      throw new Error(`Supervisor queue card ${index + 1} has status "${status}"; expected exactly "awaiting supervisor review".`);
    }
  }
}

export async function runBrowserAcceptance({ chromium, baseURL, fixture, storageStates }) {
  requireValue(chromium, "chromium");
  baseURL = requireValue(baseURL, "PLAYWRIGHT_BASE_URL").replace(/\/$/, "");
  const reviewId = requireValue(fixture?.review_id, "fixture.review_id");
  const evidenceName = requireValue(fixture?.evidence_filename, "fixture.evidence_filename");
  for (const [role, state] of Object.entries(storageStates ?? {})) requireValue(state, `${role} storage state`);

  const importerFirstNote = `Browser split proposal ${fixture.run_id}`;
  const returnNote = `Browser return for information ${fixture.run_id}`;
  const importerSecondNote = `Browser resubmission ${fixture.run_id}`;
  const approvalNote = `Browser explicit supervisor approval ${fixture.run_id}`;

  const browser = await chromium.launch({ headless: true });
  try {
    const importerA = await newContext(browser, baseURL, storageStates.importerA);
    const pageA = await importerA.newPage();

    await pageA.goto("/importer");
    await expectVisible(pageA, "Physical Receipt Exceptions");
    parsePositiveBadge(
      await pageA.getByRole("link", { name: /Physical Receipt Exceptions/i }).textContent(),
      "Importer action entry",
    );
    await assertImporterQueue(pageA, reviewId);
    await pageA.goto(`/importer/physical-receipts/${reviewId}`);
    await expectVisible(pageA, "Immutable receipt facts");
    await openEvidence(pageA, evidenceName);

    const importerB = await newContext(browser, baseURL, storageStates.importerB);
    const pageB = await importerB.newPage();
    await expectDenied(pageB, `/importer/physical-receipts/${reviewId}`, "Cross-importer direct review access");
    await importerB.close();

    await prepareSplitProposal(pageA, importerFirstNote);
    await submitProposal(pageA, reviewId);

    const supervisor = await newContext(browser, baseURL, storageStates.supervisor);
    const pageS = await supervisor.newPage();
    await pageS.goto("/internal");
    await expectVisible(pageS, "Physical Receipt Reviews");
    parsePositiveBadge(
      await pageS.getByRole("link", { name: /Physical Receipt Reviews/i }).textContent(),
      "Supervisor action entry",
    );
    await assertSupervisorQueue(pageS, reviewId);
    await pageS.goto(`/internal/physical-receipts/${reviewId}`);
    await expectVisible(pageS, "Importer proposal");
    await expectVisible(pageS, "Proposed refund");
    await expectVisible(pageS, "Proposed replacement");
    await openEvidence(pageS, evidenceName);

    const decision = pageS.locator('select[name="decision"]');
    await decision.selectOption("return_for_information");
    if (await pageS.locator('input[name="allocations_json"]').inputValue() !== "[]") {
      throw new Error("Return-for-information carried supervisor allocations.");
    }
    await pageS.getByLabel("Decision note").fill(returnNote);
    await submitSupervisorDecision(pageS, reviewId, "returned for information");

    await assertImporterQueue(pageA, reviewId);
    await pageA.goto(`/importer/physical-receipts/${reviewId}`);
    await expectVisible(pageA, "Returned for information");
    await expectVisible(pageA, returnNote);
    await prepareSplitProposal(pageA, importerSecondNote);
    await submitProposal(pageA, reviewId);

    await assertSupervisorQueue(pageS, reviewId);
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
    await submitSupervisorDecision(pageS, reviewId, "approved to existing exception");

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

    const ordinary = await newContext(browser, baseURL, storageStates.ordinaryStaff);
    const pageO = await ordinary.newPage();
    await expectDenied(pageO, `/internal/physical-receipts/${reviewId}`, "Ordinary staff direct supervisor access");
    await ordinary.close();

    await supervisor.close();
    await importerA.close();
  } finally {
    await browser.close();
  }
}
