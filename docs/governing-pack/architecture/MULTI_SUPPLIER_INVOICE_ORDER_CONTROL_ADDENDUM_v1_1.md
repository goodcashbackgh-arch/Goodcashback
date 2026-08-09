# Multi-Supplier-Invoice Order Control Addendum v1.1

**Status:** governing corrective authority to `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`

**Effective date:** 9 August 2026

**Repository baseline inspected:** `482d5dd5f25fc92592276c84fd8e4d39ea4c8f50`

This corrective addendum is deliberately narrow. It governs only an exception whose persisted identity is exactly:

```text
stage_detected = at_reconciliation
and
desired_outcome = replacement
```

Where this document is more specific for that exact identity, it controls. Every refund route and every replacement originating outside invoice reconciliation remains governed by the existing contracts and code paths.

## 1. Proven defect

The importer reconciliation lane can create an unresolved exception with:

```text
stage_detected = at_reconciliation
desired_outcome = replacement
```

That record is a reconciliation correction case, not authority to progress into the retailer replacement fulfilment workflow.

Current application behaviour has two independent escalation paths that make an accidental reconciliation replacement unsafe:

1. the supervisor exception page treats a non-refund dispute as eligible for `Accept replacement outcome`, which can reach `staff_accept_replacement_outcome_v1`;
2. the importer exception page exposes the normal `Retailer update` form, and `saveRetailerUpdateAction` can call `operator_update_dispute_retailer_update`.

The existing reconciliation `Rescind` safety correctly refuses to rescind a replacement after downstream dispute messages or other protected activity exists. Therefore merely blocking final supervisor acceptance is insufficient: the importer retailer-update lane can create downstream activity first and leave the accidental reconciliation replacement stuck.

## 2. Governing business rule

For exactly:

```text
stage_detected = at_reconciliation
and
desired_outcome = replacement
```

there is no retailer replacement workflow.

The only permitted supervisor outcome is:

```text
Reject replacement — return to invoice reconciliation
```

Rejection restores the reconciliation correction path using the already-proven Rescind mutation semantics:

```text
remove the unresolved dispute-line linkage;
remove the dispute when no lines remain, otherwise recompute its amount from remaining lines;
leave the underlying supplier invoice/manual line intact;
return the operator to invoice reconciliation;
```

The importer can then delete/correct the manual reconciliation line and upload the genuine supplier invoice through the existing invoice lane.

This correction must not alter the existing importer `rescindExceptionCaseAction`; it reuses its proven mutation semantics for the exact supervisor-controlled case.

## 3. Four-part layered guard

The implementation requires all four controls below. Two controls are not sufficient.

### 3.1 Supervisor UI guard

On `app/internal/exceptions/[dispute_id]/page.tsx`, when the exact persisted identity is:

```text
stage_detected = at_reconciliation
and
desired_outcome = replacement
```

never render `Accept replacement outcome`.

Render only the supervisor rejection control labelled materially as:

```text
Reject replacement — return to invoice reconciliation
```

All refund cases and all non-reconciliation replacement cases retain their current UI and behaviour.

### 3.2 Supervisor server guard and reject action

On `app/internal/exceptions/[dispute_id]/actions.ts`:

- `acceptReplacementOutcomeAction` must re-read server-side dispute identity and fail closed before retailer-outcome validation and before any call to `staff_accept_replacement_outcome_v1` when the exact identity is reconciliation + replacement;
- add a narrowly scoped supervisor rejection action for that exact identity only;
- the rejection action must require active staff authority, re-read the dispute server-side, require it to remain unresolved, require no replacement child, and apply the proven Rescind mutation semantics;
- if protected downstream activity already exists, fail closed rather than deleting evidence;
- do not change `staff_accept_replacement_outcome_v1`.

### 3.3 Importer UI guard

On `app/importer/exceptions/[dispute_id]/page.tsx`, for the exact reconciliation-replacement identity, do not render the `Retailer update` form.

Render an explanatory read-only notice materially equivalent to:

```text
Replacement was raised from invoice reconciliation and is awaiting supervisor review. Continue through invoice reconciliation if rejected.
```

Existing retailer history may remain visible as audit history. No other exception lane loses its retailer-update UI.

### 3.4 Importer server guard

On `app/importer/exceptions/[dispute_id]/actions.ts`, `saveRetailerUpdateAction` must re-use the server-resolved dispute returned by the existing access guard and fail closed for the exact reconciliation-replacement identity before calling `operator_update_dispute_retailer_update`.

This server guard is mandatory even though the form is hidden, because stale tabs or direct/manual submissions must not bypass the UI control.

## 4. Exact implementation scope

The authorised production change is exactly four existing application files:

```text
app/internal/exceptions/[dispute_id]/page.tsx
app/internal/exceptions/[dispute_id]/actions.ts
app/importer/exceptions/[dispute_id]/page.tsx
app/importer/exceptions/[dispute_id]/actions.ts
```

No production file outside those four is authorised by this correction without new evidence.

## 5. Explicit non-impact boundary

This correction must not add or modify:

- database migrations;
- tables, columns, constraints, triggers, RLS, grants or statuses;
- any RPC;
- `staff_accept_replacement_outcome_v1`;
- `operator_update_dispute_retailer_update`;
- `rescindExceptionCaseAction` in importer reconciliation;
- physical replacement or same-order free-replacement authorities;
- shipper behaviour;
- tracking or delivery allocation;
- customer review or holds;
- refund behaviour;
- supplier AP, supplier payment or DVA/card matching;
- customer sales release;
- Sage or VAT;
- settlement credit, funding or loyalty;
- normal replacement cases originating outside reconciliation;
- normal reconciliation refunds.

The guard predicate must not be broadened beyond the exact persisted pair `at_reconciliation` + `replacement`.

## 6. Required behavioural regression

Before release, prove at minimum:

1. a reconciliation-stage replacement does not render the supervisor Accept replacement control;
2. the same case renders only the supervisor Reject/return-to-reconciliation control;
3. direct invocation of `acceptReplacementOutcomeAction` for that case is server-blocked before retailer-outcome checks/RPC execution;
4. the importer retailer-update form is not rendered for that case;
5. direct/stale invocation of `saveRetailerUpdateAction` for that case is server-blocked before `operator_update_dispute_retailer_update`;
6. supervisor rejection applies the same safe mutation result as the existing reconciliation Rescind path and leaves the supplier invoice/manual line available for correction;
7. no retailer message or replacement child is created by the protected path;
8. reconciliation refunds remain unchanged;
9. replacements whose `stage_detected` is not `at_reconciliation` retain the existing retailer-update and supervisor-acceptance paths;
10. all four production changes are conditional on both parts of the exact identity;
11. no migration or protected backend authority changes;
12. lint/build and focused source regression pass.

## 7. Acceptance rule

The correction is complete only when the following path is deterministic:

```text
accidental reconciliation Replacement
→ importer retailer-update workflow unavailable and server-blocked
→ supervisor replacement acceptance unavailable and server-blocked
→ supervisor Reject replacement — return to invoice reconciliation
→ proven rescind mutation semantics clear the accidental exception linkage
→ manual reconciliation line remains available
→ importer deletes/corrects it and uploads the genuine supplier invoice
```

The protection is intentionally layered:

```text
importer UI guard
+ importer server guard
+ supervisor UI guard
+ supervisor server guard
```

No broader redesign is authorised.