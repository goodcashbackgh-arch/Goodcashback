import fs from 'node:fs';

const migrationPath = 'supabase/migrations/20260816123000_shipment_batch_undo_release_control_v1.sql';
const addendumPath = 'docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md';
const undoActionPath = 'app/shipper/shipments/[shipment_batch_id]/undo-action.ts';
const shipmentPagePath = 'app/shipper/shipments/[shipment_batch_id]/page.tsx';
const finalEvidencePagePath = 'app/shipper/shipments/[shipment_batch_id]/final-evidence/page.tsx';

const migration = fs.readFileSync(migrationPath, 'utf8');
const addendum = fs.readFileSync(addendumPath, 'utf8');
const undoAction = fs.readFileSync(undoActionPath, 'utf8');
const shipmentPage = fs.readFileSync(shipmentPagePath, 'utf8');
const finalEvidencePage = fs.readFileSync(finalEvidencePagePath, 'utf8');

const failures = [];
const requireMatch = (text, regex, message) => {
  if (!regex.test(text)) failures.push(message);
};
const forbidMatch = (text, regex, message) => {
  if (regex.test(text)) failures.push(message);
};

// Corrected authority must explicitly protect Groupage from mutation.
requireMatch(addendum, /Groupage is completely outside the mutation scope of this build\./,
  'Addendum missing absolute Groupage protected boundary.');
requireMatch(addendum, /Any final export evidence/,
  'Addendum missing any-final-evidence blocker.');
requireMatch(addendum, /This build may harden only the following four existing non-Groupage writers:/,
  'Addendum missing four-writer scope boundary.');
requireMatch(addendum, /This build must not change the existing permissions, grants, revokes, ownership or role exposure of any pre-existing function\./,
  'Addendum missing permission-preservation rule.');

// Zero Groupage function/ACL mutation in the migration. Reading active membership is allowed.
const protectedGroupageFunctions = [
  'shipper_create_groupage_movement_v1',
  'internal_review_final_export_evidence_document_v1',
  'groupage_recompute_movement_status_v1',
];
for (const name of protectedGroupageFunctions) {
  forbidMatch(
    migration,
    new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+public\\.${name}\\s*\\(`, 'i'),
    `Forbidden Groupage function replacement present: ${name}.`,
  );
  forbidMatch(
    migration,
    new RegExp(`(?:GRANT|REVOKE|ALTER\\s+FUNCTION).*${name}`, 'i'),
    `Forbidden Groupage permission/ownership mutation present: ${name}.`,
  );
}
requireMatch(migration, /FROM public\.shipper_groupage_movement_batches gmb[\s\S]*gmb\.active = true/,
  'Undo migration must read active Groupage membership as a blocker.');

// Only four existing functions may be redefined.
const authorisedExistingWriters = [
  'shipper_update_shipment_batch_header_v1',
  'shipper_save_export_evidence_completion_fields_v1',
  'shipper_submit_shipping_document_v1',
  'shipper_submit_final_export_evidence_v1',
];
for (const name of authorisedExistingWriters) {
  requireMatch(
    migration,
    new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+public\\.${name}\\s*\\(`, 'i'),
    `Authorised writer missing from migration: ${name}.`,
  );
  forbidMatch(
    migration,
    new RegExp(`(?:GRANT|REVOKE|ALTER\\s+FUNCTION).*${name}`, 'i'),
    `Existing ACL/ownership must not change: ${name}.`,
  );
}

const createOrReplaceNames = [...migration.matchAll(/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.([a-zA-Z0-9_]+)\s*\(/gi)].map((m) => m[1]);
const allowedDefinitions = new Set(['shipper_undo_shipment_batch_v1', ...authorisedExistingWriters]);
for (const name of createOrReplaceNames) {
  if (!allowedDefinitions.has(name)) failures.push(`Unexpected function redefinition in Undo migration: ${name}.`);
}

// New Undo authority security boundary only.
requireMatch(migration, /CREATE OR REPLACE FUNCTION public\.shipper_undo_shipment_batch_v1\s*\(/,
  'Undo RPC missing.');
requireMatch(migration, /SECURITY DEFINER[\s\S]*SET search_path = public, pg_temp/,
  'Undo migration missing SECURITY DEFINER/search_path boundary.');
requireMatch(migration, /REVOKE ALL ON FUNCTION public\.shipper_undo_shipment_batch_v1\(uuid,text\) FROM PUBLIC, anon;/,
  'Undo RPC PUBLIC/anon revoke missing.');
requireMatch(migration, /GRANT EXECUTE ON FUNCTION public\.shipper_undo_shipment_batch_v1\(uuid,text\) TO authenticated;/,
  'Undo RPC authenticated grant missing.');

// Correct blocker model.
requireMatch(migration, /FROM public\.shipper_final_export_evidence_documents d\s+WHERE d\.shipment_batch_id = p_shipment_batch_id\s*\)/,
  'Undo must block on any final-export-evidence row without review-status filtering.');
forbidMatch(migration, /shipper_final_export_evidence_documents[\s\S]{0,300}review_status\s+IN\s*\(/,
  'Undo incorrectly filters final-evidence blocker by review status.');
requireMatch(migration, /csrl\.release_status = 'active'/,
  'Active customer-sales release blocker missing.');
requireMatch(migration, /sage_posting_status = 'posted'/,
  'Posted accounting hard blocker missing.');
requireMatch(migration, /locked_for_export_pack_at IS NOT NULL/,
  'Export-lock blocker missing.');
requireMatch(migration, /outcome = 'progressed_allocated'/,
  'Mutable progressed adjustment housekeeping missing.');

// Four authorised writers must lock parent batch.
for (const name of authorisedExistingWriters) {
  const start = migration.search(new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+public\\.${name}\\s*\\(`, 'i'));
  const next = migration.indexOf('CREATE OR REPLACE FUNCTION public.', start + 10);
  const body = migration.slice(start, next === -1 ? migration.length : next);
  if (!/FROM public\.shipper_shipment_batches[\s\S]*FOR UPDATE;/.test(body)) {
    failures.push(`Parent Shipment Batch FOR UPDATE missing from authorised writer: ${name}.`);
  }
}

// UI/action scope.
requireMatch(undoAction, /rpc\("shipper_undo_shipment_batch_v1"/,
  'Shipper Undo action is not calling the governed Undo RPC.');
requireMatch(undoAction, /Undo reason is required\./,
  'Shipper Undo action does not require reason.');
requireMatch(shipmentPage, /const canUndoBatch = row\?\.status === "created";/,
  'Undo UI is not limited to created Shipment Batches.');
requireMatch(shipmentPage, />Undo Shipment Batch</,
  'Undo Shipment Batch UI control missing.');
requireMatch(finalEvidencePage, /const batchCreated = \(batch as any\)\.status === "created";/,
  'Final-evidence page does not derive created/read-only state.');
requireMatch(finalEvidencePage, /!batchCreated \? \(/,
  'Final-evidence upload is not locked in UI for non-created batches.');

if (failures.length) {
  console.error(JSON.stringify({ result: 'FAIL', failures }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({
  result: 'PASS',
  probe: 'shipment_batch_undo_release_control_source_regression_v1',
  protected_groupage_function_redefinitions: 0,
  protected_groupage_acl_mutations: 0,
  authorised_existing_writer_count: authorisedExistingWriters.length,
  unexpected_function_redefinitions: [],
  existing_writer_acl_mutations: 0,
  any_final_evidence_blocks: true,
  undo_ui_created_only: true,
  final_evidence_ui_read_only_when_not_created: true,
}, null, 2));
