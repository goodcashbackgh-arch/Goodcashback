import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const pagePath = path.join(
  root,
  "app/internal/shipping-control/customer-invoice/[shipment_batch_id]/page.tsx",
);
const source = fs.readFileSync(pagePath, "utf8");

// Preserve the existing pre-draft route and UI rather than creating a second
// preview workflow.
assert.match(
  source,
  /internal_shipping_customer_invoice_readiness_preview_v1/,
  "Existing pre-draft customer invoice preview RPC must remain in use.",
);
assert.match(
  source,
  /Customer invoice readiness preview/,
  "Existing pre-draft preview surface must remain available.",
);

// Once a draft exists, the Mini-build 3 durable release ledger is authoritative.
assert.match(
  source,
  /\.from\("customer_sales_release_lines"\)[\s\S]*?\.eq\("source_shipment_batch_id", shipmentBatchId\)[\s\S]*?\.eq\("release_status", "active"\)/,
  "Detail route must resolve active durable release membership from the selected booking.",
);
assert.match(
  source,
  /\.from\("sales_invoices"\)[\s\S]*?\.in\("id", salesInvoiceIds\)/,
  "Detail route must load the created sales invoice rather than reconstructing it.",
);
assert.match(
  source,
  /\.from\("customer_sales_release_lines"\)[\s\S]*?\.in\("sales_invoice_id", salesInvoiceIds\)[\s\S]*?\.eq\("release_status", "active"\)/,
  "Detail route must load all exact active memberships for the created invoice, including sibling bookings.",
);
assert.match(
  source,
  /Customer sales invoice detail/,
  "Post-draft detail state must be explicit.",
);
assert.match(
  source,
  /Durable line-level release membership/,
  "Post-draft page must display exact durable release lines.",
);
assert.match(
  source,
  /Ledger membership total/,
  "Post-draft page must reconcile the invoice amount to the release ledger.",
);
assert.match(
  source,
  /A draft-existing state is therefore a completed release step, not a blocker or a zero-value supplementary preview\./,
  "Post-draft page must not present the existing draft as a failed zero-value preview.",
);
assert.match(
  source,
  /Created customer document payload/,
  "Existing sales invoice payload must remain visible as a read-only mirror.",
);

// The patch is read-only and must not introduce another customer document,
// release, Sage, VAT, hold, shipment or progression write route.
for (const forbidden of [
  /createCustomerInvoiceDrafts/,
  /internal_customer_invoice_release_create_drafts_v1/,
  /\.insert\(/,
  /\.update\(/,
  /\.delete\(/,
  /recompute_order_status/,
  /operator_bulk_mark_supplier_invoice_lines_progressed/,
]) {
  assert.doesNotMatch(
    source,
    forbidden,
    `Customer invoice detail page contains forbidden write or status logic: ${forbidden}`,
  );
}

console.log(
  "PASS: existing pre-draft preview is preserved; created customer documents now display from sales_invoices plus authoritative Mini-build 3 durable release membership without adding a write route.",
);
