import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..', '..')
const baseline = '7c9ca34badee38e92c86c546e6f53a93af8da0b9'

const migrations = [
  'supabase/migrations/20260801130000_hybrid_physical_receipt_foundation_v1.sql',
  'supabase/migrations/20260801131000_hybrid_physical_receipt_integrity_v1.sql',
  'supabase/migrations/20260801131500_hybrid_physical_receipt_concurrency_v1.sql',
  'supabase/migrations/20260801131700_hybrid_physical_receipt_legacy_fail_closed_v1.sql',
  'supabase/migrations/20260801132000_hybrid_physical_receipt_position_v1.sql',
]

const sqlRegressionPath =
  'docs/testing/20260801_hybrid_physical_receipt_foundation_regression_v1.sql'
const terminalRegressionPath =
  'docs/testing/20260801_hybrid_physical_receipt_terminal_immutability_regression_v1.sql'
const impactMapPath =
  'docs/implementation/20260801_hybrid_physical_receipt_foundation_impact_map_v1.md'

const expectedChangedFiles = [
  impactMapPath,
  sqlRegressionPath,
  terminalRegressionPath,
  'docs/testing/20260801_hybrid_physical_receipt_foundation_source_regression_v1.mjs',
  ...migrations,
].sort()

function read(repoPath) {
  return readFileSync(join(root, repoPath), 'utf8')
}

function requireText(source, text, label) {
  assert.ok(source.includes(text), `${label}: missing required text: ${text}`)
}

function forbid(source, pattern, label) {
  assert.ok(!pattern.test(source), `${label}: forbidden pattern ${pattern}`)
}

const changedFiles = execFileSync(
  'git',
  ['diff', '--name-only', `${baseline}...HEAD`],
  { cwd: root, encoding: 'utf8' },
)
  .trim()
  .split('\n')
  .filter(Boolean)
  .sort()

assert.deepEqual(
  changedFiles,
  expectedChangedFiles,
  `Build 1 scope drifted. Actual changed files:\n${changedFiles.join('\n')}`,
)

assert.ok(
  changedFiles.every((file) => !file.startsWith('app/') && !file.startsWith('src/')),
  'Build 1 must not contain application/runtime code changes.',
)

const migrationSources = migrations.map((file) => ({ file, source: read(file) }))
const allMigrationSql = migrationSources.map(({ source }) => source).join('\n')

for (const { file, source } of migrationSources) {
  assert.match(source, /^BEGIN;\s*/i, `${file}: migration must start with BEGIN`)
  assert.match(source, /COMMIT;\s*$/i, `${file}: migration must end with COMMIT`)
  forbid(source, /\bCREATE\s+OR\s+REPLACE\b/i, file)
  forbid(source, /\bDROP\b[\s\S]{0,120}\bCASCADE\b/i, file)
  forbid(source, /\bfeature[_ -]?flag\b/i, file)

  const dollarTags = [...source.matchAll(/\$[A-Za-z_][A-Za-z0-9_]*\$/g)]
    .map((match) => match[0])
  for (const tag of new Set(dollarTags)) {
    assert.equal(
      dollarTags.filter((candidate) => candidate === tag).length % 2,
      0,
      `${file}: unbalanced PostgreSQL dollar-quote tag ${tag}`,
    )
  }
}

const protectedObjects = [
  'shipper_record_package_receipt_v1',
  'shipper_package_dashboard_v1',
  'customer_review_cycle_candidates_v1',
  'internal_materialize_customer_review_cycles_v1',
  'customer_review_receipt_materialize_v1',
  'shipper_tracking_review_state_v1',
  'shipper_shipment_batch_candidates_v1',
  'shipper_create_shipment_batch_v1',
  'shipper_shipment_batch_effective_lines_v1',
  'internal_customer_sales_release_sources_v1',
  'customer_sales_release_guard_v1',
  'customer_sales_release_financial_guard_v1',
  'customer_hold_create_refund_exception_v2',
  'customer_hold_refund_target_lines_v1',
  'create_replacement_child_order',
  'order_has_open_child_exceptions',
  'approve_vat_release',
  'mark_order_accounting_release_ready',
  'recompute_order_status',
  'order_reconciliation_vw',
]

for (const objectName of protectedObjects) {
  const createPattern = new RegExp(
    `\\bCREATE\\s+(?:FUNCTION|VIEW)\\s+public\\.${objectName}\\b`,
    'i',
  )
  forbid(allMigrationSql, createPattern, `protected object ${objectName}`)
}

forbid(allMigrationSql, /\bremedy_type\b/i, 'legacy remedy column')
forbid(allMigrationSql, /\bremedy_qty\b/i, 'legacy remedy quantity column')

const foundation = read(migrations[0])
const integrity = read(migrations[1])
const concurrency = read(migrations[2])
const hardening = read(migrations[3])
const position = read(migrations[4])
const regression = read(sqlRegressionPath)
const terminalRegression = read(terminalRegressionPath)
const impactMap = read(impactMapPath)

for (const requiredFile of migrations) {
  requireText(regression, requiredFile.split('/').at(-1), 'SQL regression migration list')
  requireText(impactMap, requiredFile, 'impact-map migration list')
}
requireText(impactMap, terminalRegressionPath, 'impact-map terminal regression')

requireText(
  foundation,
  "v_receipt_v1_fingerprint <> '27fb972b34258990cfa9d752cd2f927b'",
  'legacy receipt fingerprint guard',
)
requireText(foundation, 'receipt_state', 'v2 receipt state')
requireText(foundation, 'proposed_remedy_type', 'importer proposal route')
requireText(foundation, 'approved_remedy_type', 'supervisor approved route')
requireText(foundation, 'proposed_by_operator_id', 'importer proposal actor')
requireText(foundation, 'approved_by_staff_id', 'supervisor approval actor')
requireText(
  foundation,
  'REVOKE ALL ON public.physical_exception_remedy_allocations',
  'direct-write boundary',
)

requireText(
  integrity,
  'trg_shipper_package_receipt_v2_pending_commit_guard_v1',
  'deferred pending guard',
)
requireText(
  integrity,
  'Every affected disposition requires linked evidence or shared receipt evidence.',
  'affected evidence requirement',
)
requireText(integrity, "WHEN v_affected_qty = 0 THEN 'received_clean'", 'derived clean summary')
requireText(integrity, "THEN 'not_received'", 'derived not-received summary')
requireText(integrity, "THEN 'held_query'", 'derived held summary')
requireText(
  integrity,
  'Proposed/approved remedy quantity exceeds the affected receipt quantity.',
  'remedy quantity cap',
)

requireText(
  concurrency,
  'Legacy package receipt cannot supersede an exact finalised v2 receipt.',
  'v1-after-v2 compatibility block',
)
requireText(
  concurrency,
  'trg_shipper_package_receipt_00_write_compatibility_guard_v1',
  'receipt lock trigger',
)
requireText(
  concurrency,
  'trg_shipper_package_receipt_01_prepare_correction_v1',
  'single transactional correction preparation',
)
requireText(
  concurrency,
  'trg_physical_remedy_00_sequence_guard_v1',
  'remedy sequencing lock',
)

requireText(
  hardening,
  'DROP TRIGGER trg_shipper_package_receipt_v2_supersede_open_review_v1',
  'single correction authority cleanup',
)
requireText(
  hardening,
  'WHERE receipt.id = NEW.id',
  'safe pending trigger row identity',
)
forbid(hardening, /COALESCE\s*\(\s*NEW\.id\s*,\s*OLD\.id\s*\)/i, 'pending guard')
requireText(
  hardening,
  'trg_shipper_package_receipt_00a_legacy_exception_guard_v1',
  'legacy exception fail-closed ordering',
)
requireText(
  hardening,
  'trg_shipper_package_receipt_00b_header_identity_guard_v1',
  'v2 header identity ordering',
)
requireText(hardening, 'JOIN public.dispute_lines', 'legacy dispute provenance blocker')
requireText(
  hardening,
  'physical_receipt_review_supervisor_note_required_v1',
  'supervisor decision-note constraint',
)
requireText(
  hardening,
  'Terminal physical receipt review provenance is immutable.',
  'terminal review immutability',
)
requireText(
  hardening,
  'Importer remedy proposal cannot invent supplier claim or customer commercial outcome amounts.',
  'proposal financial boundary',
)
requireText(
  hardening,
  'Terminal physical remedy provenance is immutable.',
  'terminal remedy immutability',
)
requireText(
  hardening,
  'Replacement remedy cannot complete while supplier cost evidence remains pending.',
  'replacement cost completion gate',
)

const triggerOrder = [
  'trg_shipper_package_receipt_00_write_compatibility_guard_v1',
  'trg_shipper_package_receipt_00a_legacy_exception_guard_v1',
  'trg_shipper_package_receipt_00b_header_identity_guard_v1',
  'trg_shipper_package_receipt_01_prepare_correction_v1',
  'trg_shipper_package_receipt_v2_integrity_guard_v1',
]
assert.deepEqual(
  [...triggerOrder].sort(),
  triggerOrder,
  'Receipt BEFORE-trigger names no longer sort in the intended safety order.',
)

requireText(position, 'relevant_batches AS', 'scoped shipment batch selection')
requireText(
  position,
  "THEN 'receipt_not_recorded'",
  'no-receipt fail-closed blocker',
)
requireText(
  position,
  "THEN 'legacy_nonclean_quantity_unproven'",
  'legacy non-clean fail-closed blocker',
)
requireText(
  position,
  'v2_active_hold_quantity_exceeds_reviewed_quantity',
  'v2 exact reviewed hold invariant',
)
requireText(
  position,
  'v2_shipped_quantity_exceeds_reviewed_quantity',
  'v2 exact reviewed shipment invariant',
)
requireText(
  position,
  'v2_active_hold_and_shipped_exceed_reviewed_quantity',
  'v2 reviewed hold/shipment invariant',
)
requireText(
  position,
  'REVOKE ALL ON FUNCTION',
  'private scoped quantity function',
)
requireText(
  position,
  'REVOKE ALL ON public.tracking_allocation_fulfilment_position_v1',
  'private diagnostic view',
)

assert.match(regression, /^-- Rollback-only regression/i)
assert.match(regression, /ROLLBACK;\s*$/i)
requireText(regression, 'SET CONSTRAINTS', 'forced deferred pending check')
requireText(regression, 'legacy package receipt cannot supersede', 'v1-after-v2 regression')
requireText(
  regression,
  'importer proposal and supervisor approval provenance',
  'proposal/approval separation regression',
)

assert.match(terminalRegression, /^-- Rollback-only catalog regression/i)
assert.match(terminalRegression, /ROLLBACK;\s*$/i)
requireText(
  terminalRegression,
  'physical_receipt_review_terminal_immutability_guard_v1',
  'terminal review catalog regression',
)
requireText(
  terminalRegression,
  'physical_remedy_terminal_immutability_guard_v1',
  'terminal remedy catalog regression',
)

console.log(
  `PASS: ${relative(root, fileURLToPath(import.meta.url))} verified Build 1 scope, migration order, protected-object preservation, atomic v2 controls, terminal provenance, legacy fail-closed rules and exact quantity authority.`,
)
