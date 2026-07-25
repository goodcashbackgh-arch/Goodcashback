import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const cleanupPath = path.join(
  root,
  "app/importer/orders/[order_id]/operations/OrderOperationsUxCleanup.tsx",
);
const layoutPath = path.join(
  root,
  "app/importer/orders/[order_id]/operations/layout.tsx",
);

const cleanup = fs.readFileSync(cleanupPath, "utf8");
const layout = fs.readFileSync(layoutPath, "utf8");

// Root-cause guard: the card must not be inserted after the evidence section's
// parent. That placed it outside the scope used to detect an existing card and
// allowed stale copies to survive a server refresh.
assert.doesNotMatch(
  cleanup,
  /evidenceHeading\?\.parentElement\?\.insertAdjacentElement\("afterend", summary\)/,
  "Bundle summary must not be injected outside the Order evidence section.",
);
assert.match(
  cleanup,
  /evidenceHeading\.insertAdjacentElement\("afterend", summary\)/,
  "Bundle summary must be owned by the current Order evidence section.",
);

// Repeated uploads/refreshes must converge on exactly one current presentation.
assert.match(
  cleanup,
  /document\.querySelectorAll<HTMLElement>\(bundleSelector\)/,
  "The cleanup must find stale bundle cards across the current document.",
);
assert.match(
  cleanup,
  /const summary = existingBundleSummaries\.shift\(\) \?\? document\.createElement\("div"\)/,
  "The existing bundle card must be reused instead of blindly appending another.",
);
assert.match(
  cleanup,
  /existingBundleSummaries\.forEach\(\(duplicate\) => duplicate\.remove\(\)\)/,
  "Any stale duplicate bundle cards must be removed.",
);
assert.match(
  cleanup,
  /summary\.innerHTML = `[\s\S]*bundleSummary\.activeInvoiceTotalGbp[\s\S]*`;/,
  "The singleton card must be refreshed from the latest server bundle facts.",
);
assert.doesNotMatch(
  cleanup,
  /bundleSummary && !evidenceSection\.querySelector/,
  "The old create-once scoped guard must not remain.",
);

// No accounting source or calculation is replaced. The existing layout still
// derives the presentation from active supplier invoices, existing financial
// summaries and existing order-value adjustments.
assert.match(
  layout,
  /\.from\("supplier_invoices"\)/,
  "Existing supplier invoice source must remain in use.",
);
assert.match(
  layout,
  /\.from\("supplier_invoice_financial_summary"\)/,
  "Existing gross invoice summary source must remain in use.",
);
assert.match(
  layout,
  /\.from\("order_value_adjustments"\)/,
  "Existing delivery and discount classification source must remain in use.",
);
assert.match(
  layout,
  /activeInvoiceTotalGbp: invoiceTotals\.reduce\(\(sum, invoice\) => sum \+ Number\(invoice\.enteredTotalGbp \?\? 0\), 0\)/,
  "Gross active invoice totals must retain their existing calculation.",
);
assert.match(cleanup, /const variance = bundleSummary\.acceptedEstimateGbp - bundleSummary\.activeInvoiceTotalGbp/);

for (const forbidden of [
  /\.from\(/,
  /\.rpc\(/,
  /\.insert\(/,
  /\.update\(/,
  /\.delete\(/,
]) {
  assert.doesNotMatch(
    cleanup,
    forbidden,
    `Presentation cleanup must not introduce a database or workflow write/read route: ${forbidden}`,
  );
}

console.log(
  "PASS: repeated supplier-invoice refreshes retain one current order bundle summary inside the evidence section; existing invoice, adjustment, accounting and workflow sources are unchanged.",
);
