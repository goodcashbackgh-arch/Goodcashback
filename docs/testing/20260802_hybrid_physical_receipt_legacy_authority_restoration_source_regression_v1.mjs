#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.cwd();
const migrationPath = path.join(
  root,
  'supabase/migrations/20260802110000_hybrid_physical_receipt_restore_legacy_authorities_v1.sql',
);

const sql = fs.readFileSync(migrationPath, 'utf8');
const failures = [];

function requirePattern(pattern, description) {
  if (!pattern.test(sql)) failures.push(`missing: ${description}`);
}

function forbidPattern(pattern, description) {
  if (pattern.test(sql)) failures.push(`forbidden: ${description}`);
}

requirePattern(
  /ALTER FUNCTION public\.physical_remedy_allocation_guard_v1\(\)\s+RENAME TO physical_remedy_allocation_guard_v2;/i,
  'the installed Build-2 guard is versioned by object rename rather than body replacement',
);
requirePattern(
  /CREATE VIEW public\.order_reconciliation_v2_vw AS/i,
  'the Build-4 reconciliation calculation is preserved under an additive v2 view',
);
requirePattern(
  /CREATE OR REPLACE VIEW public\.order_reconciliation_vw AS/i,
  'the already-replaced legacy view is restored in place to preserve dependent object identity',
);
requirePattern(
  /v_trigger_function IS DISTINCT FROM 'physical_remedy_allocation_guard_v2'/i,
  'postflight proves the existing hybrid trigger remains bound to v2',
);
requirePattern(
  /v_legacy_view_fingerprint IS DISTINCT FROM '89cc95922a2b8ec1fa040ba79f12907a'/i,
  'postflight proves the exact pre-Build-4 reconciliation definition is restored',
);
requirePattern(
  /to_regprocedure\('public\.physical_remedy_allocation_guard_v2\(\)'\) IS NOT NULL/i,
  'preflight refuses to replace an existing v2 guard',
);
requirePattern(
  /to_regclass\('public\.order_reconciliation_v2_vw'\) IS NOT NULL/i,
  'preflight refuses to replace an existing v2 reconciliation view',
);

forbidPattern(
  /CREATE OR REPLACE FUNCTION\s+public\.physical_remedy_allocation_guard_v[12]\s*\(/i,
  'a literal in-place physical remedy guard replacement',
);
forbidPattern(
  /DROP FUNCTION\s+(?:IF EXISTS\s+)?public\.physical_remedy_allocation_guard_v[12]\s*\(/i,
  'dropping either physical remedy guard authority',
);
forbidPattern(
  /DROP VIEW\s+(?:IF EXISTS\s+)?public\.order_reconciliation_vw/i,
  'dropping the legacy reconciliation view and breaking dependencies',
);

if (failures.length > 0) {
  console.error('FAIL — legacy authority restoration source regression');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log('PASS — legacy authority restoration is additive/versioned, preserves the hybrid trigger binding, and restores the exact legacy reconciliation authority');
