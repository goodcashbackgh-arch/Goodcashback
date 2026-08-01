# VAT Adjustment Multi-Source Allocation Addendum v1

## 1. Status and governing relationship

This addendum is a separate, additive contract for multi-source provenance on VAT adjustment journals.

It does not amend, replace or reinterpret:

- `VAT_RETURN_INTEGRITY_EVIDENCE_AND_ATOMIC_SAGE_POSTING_ADDENDUM_v1.md`;
- `VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md`;
- any migration already deployed for VAT calculation, evidence locking or Sage posting.

The previously deployed contracts remain authoritative for their original scope.

Implementation must begin from the current reviewed `main` definition hashes. Any mismatch between deployed and reviewed function definitions must abort replacement rather than overwrite newer work.

## 2. Problem being closed

The current VAT adjustment journal header contains one nullable `vat_return_run_line_id`. That model can represent a journal supported by one VAT source line, but it cannot provide first-class provenance when one accounting adjustment is supported by several compatible VAT source lines.

Example:

```text
Source A: £60 Box 6 increase
Source B: £40 Box 6 increase
Required Sage adjustment: £100 Box 6 increase
```

The correct result is one balanced £100 Sage journal with two internal source allocations of £60 and £40.

This is a preventive integrity capability. The production diagnostic summary recorded before this addendum found:

- 3 existing VAT adjustment journals;
- 0 journals without a direct source line;
- 0 source lines reused by multiple journals;
- 0 conservative active multi-source candidate groups.

Those facts do not authorise historical mutation. Existing journals are grandfathered and remain unchanged.

## 3. Required outcome

The build must allow one VAT adjustment journal to be supported by one or more compatible VAT return source lines while preserving exactly one existing balanced Sage journal payload.

The build must prove:

1. every allocation belongs to the same VAT return as its journal;
2. every allocated source is eligible for the journal's box, direction and adjustment semantics;
3. the total allocated amount equals the journal amount exactly to two decimal places;
4. concurrent callers cannot overallocate a source;
5. allocations become immutable before approval and remain immutable thereafter;
6. the Sage request payload, endpoint, line count, account roles and debit/credit values remain governed by the existing contract;
7. legacy journals and the deployed VAT integrity controls remain unchanged.

## 4. Locked implementation scope

The build contains exactly these work items:

1. an additive source-allocation table linked to existing VAT adjustment journals and VAT return lines;
2. versioned v2 preview and materialisation functions that may group compatible source lines into one proposal;
3. transactional allocation creation and availability validation;
4. approval-time allocation validation and immutable allocation evidence;
5. read-only UI evidence showing the source breakdown behind a journal;
6. regression coverage proving identical behavior for existing single-source journals and non-regression of deployed VAT and Sage controls.

Anything not required to deliver those work items is out of scope.

## 5. Explicit exclusions

The build must not include:

- any rewrite of the VAT calculation engine;
- any change to expected VAT box calculations;
- any change to the Box 6 uninvoiced-funding finaliser;
- any change to export-evidence reinstatement linkage;
- any change to final VAT evidence storage or v2 locking;
- any change to the atomic Sage posting claim;
- a new journal status;
- additional Sage journal ledger lines;
- a Sage payload, endpoint, date, reference or tax-return flag change;
- historical journal backfill or repair;
- mutation of approved, posted, included, reversed or locked historical records;
- automatic retry after an unknown Sage network outcome;
- broad role, RLS, storage or VAT workbench refactoring;
- grouping across incompatible accounting or correction semantics.

A newly discovered issue outside this list must be documented separately and left unchanged.

## 6. Data model

### 6.1 Allocation table

Add a table with the following logical contract:

```text
vat_return_adjustment_journal_source_allocations
  id
  vat_return_adjustment_journal_id
  vat_return_run_line_id
  allocated_amount_gbp
  source_snapshot_json
  created_at
```

Required relational rules:

- `vat_return_adjustment_journal_id` references the existing journal header;
- `vat_return_run_line_id` references the existing VAT return line;
- `allocated_amount_gbp` is greater than zero;
- one source line may appear at most once within one journal;
- direct table writes by normal authenticated clients are prohibited;
- creation occurs only through a guarded database function;
- mutation or deletion is prohibited once the journal leaves an editable pre-approval state.

The existing `vat_return_adjustment_journal_lines` table remains solely the Sage debit/credit line template and must not be reused for source provenance.

### 6.2 Journal version markers

Add nullable relational fields to the existing journal header:

```text
source_allocation_version
source_allocation_hash
```

Rules:

- `NULL` means a legacy journal governed by the existing single-source behavior;
- `multi_source_v1` means allocation validation is mandatory;
- no legacy row is backfilled merely to satisfy the new model;
- the allocation hash is separate from the existing Sage request payload hash.

## 7. Grouping contract

The v2 preview may group source lines only when all grouping attributes required by the existing journal construction are identical.

At minimum, the grouping key must include:

- VAT return run;
- target VAT box;
- adjustment direction;
- adjustment type;
- VAT-box account role;
- balancing account role;
- tax-return inclusion treatment;
- journal date basis;
- correction, reversal and prior-return semantics;
- any deterministic input used to derive the journal reference or idempotency key.

Lines must not be grouped merely because they share a VAT box and direction.

If compatibility cannot be proven from reviewed data, the preview must keep the sources as separate proposals or raise a blocker. It must never guess.

## 8. Amount contract

The allocation basis must follow the same amount semantics already used by the existing proposal logic:

- Boxes 1 and 4 use the governed VAT amount basis;
- Boxes 6 and 7 use the governed net amount basis;
- signs are represented by the journal direction while stored allocated amounts remain positive;
- the exact sum of allocation amounts must equal `vat_return_adjustment_journals.amount_gbp` at two-decimal precision.

No allocation may exceed the source's governed available amount after subtracting amounts consumed by other journals in consuming states.

## 9. Availability and concurrency

Allocation creation must be atomic.

The guarded function must:

1. lock the journal row;
2. lock requested VAT source rows in deterministic identifier order;
3. reject sources from another return;
4. reject inactive, superseded, corrected or ineligible sources;
5. calculate previously consumed amounts using the explicitly governed consuming status set;
6. reject any over-allocation;
7. insert the complete allocation set in one transaction;
8. calculate and persist the deterministic allocation hash;
9. roll back the entire operation if any validation fails.

The implementation addendum or migration comments must explicitly list the statuses that consume availability. This set must be approved after the remaining production diagnostic outputs have been reviewed. It must not be inferred silently in code.

## 10. Allocation hash

The allocation hash must be deterministic and separate from the Sage payload hash.

Its canonical input must contain the ordered allocation evidence required to prove provenance, including:

- source VAT return line identifier;
- allocated amount;
- immutable source snapshot digest or canonical source snapshot fields;
- allocation contract version.

Ordering must be deterministic. Equivalent allocation sets must produce the same hash regardless of input order.

Changing an allocation after approval must be impossible rather than merely detectable.

## 11. Preview and materialisation functions

Introduce versioned functions rather than silently changing the existing v1 behavior:

```text
staff_preview_vat_adjustment_journal_proposals_v2
staff_materialise_vat_adjustment_journal_proposals_v2
```

The v2 materialiser must create, in one database transaction:

- one journal header for each grouped proposal;
- exactly the existing two balanced journal lines;
- one or more source-allocation records;
- the allocation version and allocation hash.

For a single-source proposal, v2 must create exactly one allocation equal to the journal amount and must produce the same Sage accounting result as v1.

The existing v1 functions remain unchanged during shadow rollout.

## 12. Approval boundary

A `multi_source_v1` journal cannot become `admin_approved` unless the database proves:

- at least one allocation exists;
- allocation total equals journal amount;
- every source belongs to the journal return;
- every source remains active and adjustment-eligible;
- every source remains compatible with the journal grouping key;
- no source is overallocated;
- the stored allocation hash matches the canonical allocation set;
- the existing Sage request payload hash remains valid;
- exactly two journal ledger lines exist and balance;
- no open blocker prevents approval.

Allocation insert, update and delete must be rejected after approval and in every later status.

## 13. Sage posting non-regression

The posting integration must continue to read the existing journal header and two existing journal lines.

The allocation records are internal provenance evidence only. They must not alter:

- the `/journals` endpoint;
- HTTP method;
- journal date;
- journal reference;
- description;
- ledger account identifiers;
- debit and credit values;
- tax-return inclusion flags;
- Sage response handling;
- atomic first-wins posting claim;
- retry and unknown-outcome rules.

For an equivalent journal total and accounts, v1 and v2 must generate byte-equivalent Sage request content after canonical serialization.

## 14. UI contract

The existing adjustment review workflow remains unchanged for single-source journals.

For a versioned journal, the UI may display a read-only source allocation table showing:

- source reference;
- source type or line kind;
- source governed amount;
- allocated amount;
- allocation total;
- allocation validation state.

Approval remains disabled when allocation validation is incomplete or failed.

The UI must not be the enforcement boundary. All critical controls remain database enforced.

## 15. Rollout

The rollout is staged:

1. complete and retain the production diagnostic evidence;
2. add the table, version fields, RLS, guarded functions and diagnostic views without routing production materialisation to v2;
3. run v2 preview in shadow mode against representative returns;
4. prove all existing single-source proposals match v1 totals, accounts, references and Sage request content;
5. test a controlled `£60 + £40 = £100` multi-source fixture;
6. test two concurrent attempts to consume the same source capacity;
7. test rollback after partial allocation failure;
8. enable v2 only for explicitly versioned new materialisations;
9. retain v1 temporarily for legacy and controlled fallback use;
10. consider v1 restriction only in a later separately reviewed hardening change.

No production Sage call is required to validate allocation concurrency. Posting tests may use rollback-only database simulation and payload comparison. Any real Sage posting requires separate explicit approval.

## 16. Required regression evidence

The build is not complete until tests prove:

- the 3 existing journals are unchanged;
- historical posted Sage identifiers, references and payload hashes are unchanged;
- locked VAT returns remain immutable;
- final evidence upload and v2 lock behavior remain unchanged;
- Box 6 finaliser results remain unchanged;
- export reinstatement linkage remains unchanged;
- the atomic Sage claim remains first-wins;
- a single-source v2 journal matches the existing v1 Sage payload;
- a compatible multi-source fixture creates one journal and several exact allocations;
- incompatible sources are not grouped;
- concurrent over-allocation has exactly one successful claimant or otherwise preserves total capacity;
- approved allocations cannot be inserted, updated or deleted;
- failed validation rolls back header, lines and allocations together;
- no allocation processing sends a Sage request.

## 17. Pre-implementation gate

Code implementation must not begin until the remaining read-only diagnostic outputs have been reviewed for:

- cross-return source links;
- journal-to-source amount differences under the correct box basis;
- inactive or no-longer-adjustment-required linked sources;
- reversal and correction patterns;
- malformed or unbalanced existing two-line journals.

If any result is non-empty, it must be classified before implementation as either:

- expected governed history;
- a separate repair issue;
- or a required rule in this addendum.

No result may be silently ignored.
