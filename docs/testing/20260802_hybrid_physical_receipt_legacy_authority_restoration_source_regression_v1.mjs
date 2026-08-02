#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.cwd();
const migrationPath = path.join(
  root,
  'supabase/migrations/20260802110000_hybrid_physical_receipt_restore_legacy_authorities_v1.sql',
);
const foundationPath = path.join(
  root,
  'supabase/migrations/20260801131000_hybrid_physical_receipt_integrity_v1.sql',
);
const addendumPath = path.join(
  root,
  'docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_AUTHORITY_VERSIONING_CORRECTION_ADDENDUM_v1.md',
);

const sql = fs.readFileSync(migrationPath, 'utf8');
const foundation = fs.readFileSync(foundationPath, 'utf8');
const addendum = fs.readFileSync(addendumPath, 'utf8');
const failures = [];

function requirePattern(pattern, description) {
  if (!pattern.test(sql)) failures.push(`missing: ${description}`);
}

function forbidPattern(pattern, description) {
  if (pattern.test(sql)) failures.push(`forbidden: ${description}`);
}

function extractGuard(source) {
  const match = source.match(
    /CREATE FUNCTION public\.physical_remedy_allocation_guard_v1\(\)[\s\S]*?\n\$function\$;/,
  );
  return match?.[0] ?? null;
}

const foundationGuard = extractGuard(foundation);
const restoredGuard = extractGuard(sql);

if (!foundationGuard) failures.push('missing: foundation v1 guard source');
if (!restoredGuard) failures.push('missing: literal restored v1 guard source');
if (foundationGuard && restoredGuard && foundationGuard !== restoredGuard) {
  failures.push('wrong: restored v1 guard is not byte-for-byte the foundation definition');
}

requirePattern(
  /HYBRID_PHYSICAL_RECEIPT_BUILD_4_AUTHORITY_VERSIONING_CORRECTION_ADDENDUM_v1\.md/i,
  'migration declares the governing correction addendum',
);
requirePattern(
  /ALTER FUNCTION public\.physical_remedy_allocation_guard_v1\(\)\s+RENAME TO physical_remedy_allocation_guard_v2;/i,
  'installed Build-2 guard is versioned by object rename',
);
requirePattern(
  /md5\(pg_get_functiondef\('public\.physical_remedy_allocation_guard_v2\(\)'::regprocedure\)\)/i,
  'v2 exact Build-2 function fingerprint is verified',
);
requirePattern(
  /md5\(\(SELECT p\.prosrc[\s\S]*physical_remedy_allocation_guard_v1/i,
  'restored v1 source fingerprint is verified independently',
);
requirePattern(
  /t\.tgfoid[\s\S]*v_v2_oid/i,
  'trigger object-OID binding to v2 is verified',
);
requirePattern(
  /CREATE VIEW public\.order_reconciliation_v2_vw AS/i,
  'Build-4 reconciliation is preserved under additive v2',
);
requirePattern(
  /CREATE OR REPLACE VIEW public\.order_reconciliation_vw AS/i,
  'legacy reconciliation is restored without dropping dependent identity',
);
requirePattern(
  /canonical AS \(SELECT \* FROM public\.order_reconciliation_v2_vw\)/i,
  'Build-4 anomaly model explicitly reads v2',
);
requirePattern(
  /b4_legacy_dependents_before/i,
  'exact pre-restoration dependency identities are captured',
);
requirePattern(
  /pg_describe_object\(d\.classid, d\.objid, d\.objsubid\)/i,
  'dependency comparison records exact object identities',
);
requirePattern(
  /EXCEPT[\s\S]*Unexpected legacy reconciliation dependency identity changed/i,
  'exact dependency identities are compared in both directions',
);
requirePattern(
  /v_legacy_fingerprint IS DISTINCT FROM '89cc95922a2b8ec1fa040ba79f12907a'/i,
  'exact legacy reconciliation fingerprint is verified',
);
requirePattern(
  /COMMIT;\s*$/i,
  'correction remains one atomic transaction',
);

forbidPattern(
  /CREATE OR REPLACE FUNCTION\s+public\.physical_remedy_allocation_guard_v[12]\s*\(/i,
  'in-place physical remedy guard replacement',
);
forbidPattern(
  /DROP FUNCTION\s+(?:IF EXISTS\s+)?public\.physical_remedy_allocation_guard_v[12]\s*\(/i,
  'dropping either physical remedy guard',
);
forbidPattern(
  /EXECUTE\s+v_definition/i,
  'dynamic function reconstruction',
);
forbidPattern(
  /pg_get_functiondef[\s\S]{0,300}\breplace\s*\(/i,
  'function-definition text replacement',
);
forbidPattern(
  /DROP VIEW\s+(?:IF EXISTS\s+)?public\.order_reconciliation_vw/i,
  'dropping the legacy reconciliation view',
);

const protectedRelations = [
  'orders',
  'disputes',
  'dispute_lines',
  'supplier_invoices',
  'supplier_invoice_lines',
  'customer_sales_releases',
  'shipper_shipment_batches',
];
for (const relation of protectedRelations) {
  const writePattern = new RegExp(
    `\\b(?:INSERT\\s+INTO|UPDATE|DELETE\\s+FROM|ALTER\\s+TABLE|DROP\\s+TABLE|TRUNCATE)\\s+public\\.${relation}\\b`,
    'i',
  );
  forbidPattern(writePattern, `write or DDL against protected relation public.${relation}`);
}

const protectedFunctions = [
  'approve_vat_release',
  'mark_order_accounting_release_ready',
  'recompute_order_status',
  'enforce_status_transition',
  'enforce_order_locks',
  'staff_accept_replacement_outcome_v1',
  'create_replacement_child_order',
];
for (const functionName of protectedFunctions) {
  const replacementPattern = new RegExp(
    `CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+public\\.${functionName}\\s*\\(`,
    'i',
  );
  forbidPattern(replacementPattern, `creation or replacement of protected function ${functionName}`);
}

if (!addendum.includes('No old application page, RPC, accounting authority, VAT authority, status authority or unrelated database object may be redirected.')) {
  failures.push('missing: addendum freezes existing-caller non-redirection');
}
if (!addendum.includes('The correction changes only:')) {
  failures.push('missing: addendum contains explicit scope boundary');
}

if (failures.length > 0) {
  console.error('FAIL — Build 4 authority-versioning correction source regression');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log('PASS — correction is governed, literal, additive/versioned, dependency-exact and contains no protected-scope writes');
