#!/usr/bin/env node
import fs from 'node:fs';

const migrationPath = 'supabase/migrations/20260802110000_hybrid_physical_receipt_restore_legacy_authorities_v1.sql';
const foundationPath = 'supabase/migrations/20260801131000_hybrid_physical_receipt_integrity_v1.sql';
const build4Path = 'supabase/migrations/20260801210000_hybrid_physical_receipt_build_4_lifecycle_reconciliation_v1.sql';
const legacyPath = 'supabase/migrations/20260724_order_reconciliation_signed_nonphysical_v1.sql';
const addendumPath = 'docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_AUTHORITY_VERSIONING_CORRECTION_ADDENDUM_v1.md';
const sql = fs.readFileSync(migrationPath, 'utf8');
const foundation = fs.readFileSync(foundationPath, 'utf8');
const build4 = fs.readFileSync(build4Path, 'utf8');
const legacy = fs.readFileSync(legacyPath, 'utf8');
const failures = [];
const requirePattern = (p, label) => { if (!p.test(sql)) failures.push(`missing: ${label}`); };
const forbidPattern = (p, label) => { if (p.test(sql)) failures.push(`forbidden: ${label}`); };
const slice = (source, start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start))).trim();

if (!fs.existsSync(addendumPath)) failures.push('missing: correction addendum');
const foundationGuard = slice(foundation, 'CREATE FUNCTION public.physical_remedy_allocation_guard_v1()', '\n\nCREATE TRIGGER trg_physical_remedy_allocation_guard_v1');
const restoredGuard = slice(sql, 'CREATE FUNCTION public.physical_remedy_allocation_guard_v1()', '\n\nREVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v1()');
if (restoredGuard !== foundationGuard) failures.push('wrong: restored v1 is not the complete literal foundation guard');
const exactBuild4 = slice(build4, 'create or replace view public.order_reconciliation_vw as', '\n\ncomment on view public.order_reconciliation_vw')
  .replace('create or replace view public.order_reconciliation_vw as', 'CREATE VIEW public.order_reconciliation_v2_vw AS');
if (!sql.includes(exactBuild4)) failures.push('wrong: v2 reconciliation is not the exact Build 4 body');
const exactLegacy = slice(legacy, 'CREATE OR REPLACE VIEW public.order_reconciliation_vw AS', '\n\nCOMMENT ON VIEW public.order_reconciliation_vw');
if (!sql.includes(exactLegacy)) failures.push('wrong: legacy reconciliation is not restored exactly');

requirePattern(/ALTER FUNCTION public\.physical_remedy_allocation_guard_v1\(\)\s*RENAME TO physical_remedy_allocation_guard_v2;/i, 'literal guard rename');
requirePattern(/32e1d3eb9161cdc3e09114edb8c0d3c0/, 'exact Build 2 pre-rename fingerprint');
requirePattern(/404fff52528bbd7d963df8809e6f23a9/, 'independent frozen v1 body\/metadata hash');
requirePattern(/guard_oid[\s\S]*guard_owner[\s\S]*guard_acl[\s\S]*guard_canonical_md5/i, 'v2 OID, owner, ACL and canonical hash capture');
requirePattern(/v2 OID, owner, ACL or canonical hash changed/i, 'v2 metadata preservation assertion');
requirePattern(/trigger_oid[\s\S]*trigger_function_oid/i, 'trigger OID and function OID capture');
requirePattern(/t\.oid = s\.trigger_oid AND t\.tgfoid = s\.guard_oid/i, 'trigger binding by OID');
requirePattern(/CREATE VIEW public\.order_reconciliation_v2_vw AS/i, 'v2 reconciliation creation');
requirePattern(/canonical as \(select \* from public\.order_reconciliation_v2_vw\)/i, 'anomaly reads v2');
requirePattern(/b4_legacy_dependents_before[\s\S]*pg_identify_object/i, 'exact dependency identities captured');
requirePattern(/SELECT \* FROM b4_legacy_dependents_before EXCEPT SELECT \* FROM dependencies_after[\s\S]*SELECT \* FROM dependencies_after EXCEPT SELECT \* FROM b4_legacy_dependents_before/i, 'dependency identity sets compared both ways');
requirePattern(/89cc95922a2b8ec1fa040ba79f12907a/, 'legacy fingerprint');
requirePattern(/aclexplode\(COALESCE\(p\.proacl, acldefault\('f', p\.proowner\)\)\)/i, 'catalog-safe PUBLIC ACL verification');
requirePattern(/^BEGIN;[\s\S]*NOTIFY pgrst, 'reload schema';\s*\n\s*COMMIT;\s*$/im, 'single committed transaction and schema reload');

forbidPattern(/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.physical_remedy_allocation_guard/i, 'guard CREATE OR REPLACE');
forbidPattern(/DROP\s+FUNCTION[\s\S]*physical_remedy_allocation_guard_v[12]/i, 'guard drop');
forbidPattern(/\bEXECUTE\s+(?:format\s*\(|v_|')/i, 'dynamic EXECUTE');
forbidPattern(/pg_get_functiondef[\s\S]{0,400}\breplace\s*\(/i, 'pg_get_functiondef reconstruction');
forbidPattern(/\breplace\s*\(\s*pg_get_functiondef/i, 'replace reconstruction');
forbidPattern(/DROP\s+TRIGGER|CREATE\s+TRIGGER/i, 'trigger drop or recreation');
forbidPattern(/has_function_privilege\(\s*'PUBLIC'/i, 'PUBLIC treated as a login role');
for (const table of ['orders','disputes','dispute_lines','supplier_invoices','supplier_invoice_lines','customer_sales_releases','shipper_shipment_batches'])
  forbidPattern(new RegExp(`\\b(?:insert\\s+into|update|delete\\s+from|truncate|alter\\s+table)\\s+public\\.${table}\\b`, 'i'), `business write to ${table}`);
for (const authority of ['approve_vat_release','mark_order_accounting_release_ready','recompute_order_status','enforce_status_transition','enforce_order_locks','staff_accept_replacement_outcome_v1','create_replacement_child_order','order_has_open_child_exceptions','fund','shipment','refund','customer_balance','sage','payout','accounts_payable'])
  forbidPattern(new RegExp(`create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.[^\\s(]*${authority}`, 'i'), `unrelated authority replacement matching ${authority}`);

if (failures.length) { console.error('FAIL — authority restoration source regression'); failures.forEach(x => console.error(`- ${x}`)); process.exit(1); }
console.log('PASS — governed authority restoration is literal, versioned, identity-exact, fail-closed and scope-contained');
