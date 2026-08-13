import assert from "node:assert/strict";
import fs from "node:fs";

const pagePath = "app/customer/orders/[secure_order_link]/review/page.tsx";
const migrationPath = "supabase/migrations/20260813_customer_hold_history_item_identity_v1.sql";

const page = fs.readFileSync(pagePath, "utf8");
const migration = fs.readFileSync(migrationPath, "utf8");

// Governing authority: CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1
// Sections 16-17 only.

// Customer history contract: only the three additive item-identity properties.
assert.match(page, /line_description\?: string \| null;/);
assert.match(page, /line_qty\?: number \| string \| null;/);
assert.match(page, /line_amount_inc_vat_gbp\?: number \| string \| null;/);

// Historical identity must render only for line-scoped holds with an identity.
assert.match(page, /hold\.requested_scope === "line" && hold\.line_description/);
assert.match(page, /\{hold\.line_description\}/);
assert.match(page, /Qty \{hold\.line_qty \?\? "—"\}/);

// Null amount must not be fabricated as £0.00; a genuine zero still passes != null.
assert.match(page, /hold\.line_amount_inc_vat_gbp != null \? ` · \$\{money\(hold\.line_amount_inc_vat_gbp\)\}` : ""/);
assert.doesNotMatch(page, /Qty \{hold\.line_qty \?\? "—"\} · \{money\(hold\.line_amount_inc_vat_gbp\)\}/);

// Migration must fail closed on unexpected live RPC drift before replacement.
assert.match(migration, /md5\(p\.prosrc\)/);
assert.match(migration, /67da874101ecfa2620169d89fb5fec9c/);
assert.match(migration, /Customer review RPC drift detected/);

// Authoritative historical identity relationship only.
assert.match(migration, /LEFT JOIN public\.supplier_invoice_lines hsil\s+ON hsil\.id = h\.supplier_invoice_line_id/);
assert.match(migration, /'line_description', hsil\.description/);
assert.match(migration, /'line_qty', hsil\.qty/);
assert.match(migration, /'line_amount_inc_vat_gbp', hsil\.amount_inc_vat_gbp/);

// No hold lifecycle/state mutation is authorised.
assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.customer_pre_shipment_hold_requests/i);
assert.doesNotMatch(migration, /UPDATE\s+public\.customer_pre_shipment_hold_requests/i);
assert.doesNotMatch(migration, /DELETE\s+FROM\s+public\.customer_pre_shipment_hold_requests/i);

// CREATE OR REPLACE must preserve existing privileges; this migration must not rewrite them.
assert.doesNotMatch(migration, /REVOKE\s+ALL\s+ON\s+FUNCTION\s+public\.customer_pre_shipment_hold_review_v1/i);
assert.doesNotMatch(migration, /GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.customer_pre_shipment_hold_review_v1/i);

// Do not expand customer exposure beyond the authorised three history fields.
for (const forbiddenJsonKey of [
  "'invoice_ref'",
  "'tracking_ref'",
  "'supplier_invoice_id'",
  "'vat_amount'",
  "'ocr_status'",
  "'dva'",
  "'sage_status'",
]) {
  assert.equal(
    migration.includes(forbiddenJsonKey),
    false,
    `migration must not add internal customer payload field ${forbiddenJsonKey}`
  );
}

console.log(JSON.stringify({
  regression_result: "PASS",
  proof: "history identity is line-scoped only; null amount is not fabricated; migration fails closed on live RPC drift; only the existing supplier line relationship is used; no hold-table DML, privilege rewrite, or unauthorised internal payload field is present"
}, null, 2));
