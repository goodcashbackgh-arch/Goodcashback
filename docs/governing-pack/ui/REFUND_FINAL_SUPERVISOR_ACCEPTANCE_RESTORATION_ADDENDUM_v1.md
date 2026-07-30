# Refund Final Supervisor Acceptance Restoration Addendum v1

Status: governing compatibility and corrective-build addendum

## 1. Purpose

This addendum locks the refund exception flow so that retailer acceptance does not itself approve the final refund outcome.

The existing supervisor control remains authoritative:

```text
supervisor approves refund pursuit
→ operator/importer contacts retailer
→ operator/importer records retailer response
→ supervisor accepts final refund outcome
→ refund evidence / refund-credit processing continues
```

This restores alignment with the existing exception UI and with `CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1.md`, which requires the operator/importer to record the retailer response and the supervisor to accept or reject the final outcome.

## 2. Defect being corrected

The current `public.operator_update_dispute_retailer_update(uuid,text,text)` contains a refund-only branch which, when:

- the retailer outcome is `retailer_accepted`;
- the dispute outcome is `refund`; and
- refund pursuit has already been supervisor-approved;

attempts to advance the parent dispute directly to:

```text
awaiting_refund_credit
```

from statuses including:

```text
raised
under_review
approved_refund
```

The direct transition from `raised` to `awaiting_refund_credit` is not a legal status transition and is correctly rejected by the existing transition guard.

The defect is therefore the automatic parent-dispute advancement inside the operator/importer retailer-update RPC, not the transition guard.

## 3. Governing final flow

### Supervisor side

```text
1. Supervisor approves refund pursuit / push to operator.
2. Existing refund_approved_at evidence is retained.
3. Supervisor waits for retailer outcome.
4. When retailer acceptance is successfully recorded, the existing
   “Accept final refund outcome” control becomes available.
5. Supervisor accepts the final refund outcome.
6. Existing supervisor action advances the dispute through the legal status spine:

   raised
   → under_review
   → approved_refund
   → awaiting_refund_credit

7. Existing refund evidence and refund-credit processing continues unchanged.
```

### Operator/importer side

```text
1. Operator/importer records retailer reply and retailer outcome.
2. Existing dispute-line conversation status is updated.
3. retailer_accepted maps to retailer_response_received.
4. The operator/importer save does not change disputes.status.
5. Control returns to the existing supervisor final-outcome acceptance step.
```

For the other retailer outcomes, existing behaviour remains unchanged:

```text
still_waiting        → retailer_contacted
retailer_disputed    → awaiting_retailer_resolution
more_info_requested  → retailer_draft_ready
```

None of those outcomes may advance the parent refund status.

## 4. Corrective build

Implement one new forward-only corrective migration.

Do not edit, rewrite, delete, or amend the historical 24 July migration.

The corrective migration must `CREATE OR REPLACE` only:

```text
public.operator_update_dispute_retailer_update(uuid,text,text)
```

The replacement function must preserve the current function's existing:

- authentication requirement;
- active operator check;
- operator/importer linkage check;
- retailer-outcome validation;
- required retailer-response validation;
- retailer reply insertion into `dispute_messages`;
- conversation-status mapping;
- unresolved dispute-line update;
- zero-updated-line fail-closed behaviour;
- existing execution permissions and security model;
- existing successful return payload where compatible.

The only functional removal is the refund branch that updates `public.disputes.status` to `awaiting_refund_credit` from the operator/importer retailer-update RPC.

The corrected RPC must not update `public.disputes.status` at all.

## 5. Explicit non-changes / blast-radius lock

This build must not change:

- the historical 24 July migration file;
- supervisor UI;
- supervisor buttons;
- `approveRefundPursuitAction`;
- `acceptFinalRefundOutcomeAction`;
- replacement-outcome handling;
- `status_transitions` data;
- `enforce_status_transition` or its trigger;
- customer hold flow;
- customer review flow;
- dispute creation/conversion rules;
- return/collection handling;
- refund evidence submission or review;
- credit-note controls;
- DVA/card reconciliation;
- supplier settlement;
- Sage/accounting;
- VAT logic;
- order totals;
- customer sales documents;
- navigation, labels, permissions, or role boundaries.

No new status, workbench, button, approval, queue, or accounting route is permitted by this addendum.

## 6. Why this resolves the transition failure

Before correction, operator/importer retailer acceptance can attempt:

```text
raised → awaiting_refund_credit
```

which the transition guard rejects.

After correction, operator/importer retailer acceptance leaves the parent dispute status unchanged and only records the retailer conversation outcome.

The supervisor then uses the existing final-acceptance action, which follows the already-supported legal sequence:

```text
raised → under_review → approved_refund → awaiting_refund_credit
```

The transition guard remains unchanged and continues to protect the status spine.

## 7. Failure and correction behaviour

Before final supervisor acceptance, an operator/importer may correct a mistakenly selected retailer conversation outcome by saving the correct outcome later.

Only a successfully recorded `retailer_accepted` outcome with an existing retailer reply should make the supervisor final-acceptance control available.

The operator/importer correction mechanism must not itself move or reverse `public.disputes.status`.

Once the supervisor has accepted the final refund outcome and the dispute has entered `awaiting_refund_credit`, downstream correction remains governed by the existing exception/refund controls. This addendum creates no new reversal route.

## 8. Minimum regression proof

The corrective build must prove all of the following:

1. A supervisor-approved refund dispute at `raised` remains `raised` after operator/importer saves `retailer_accepted`.
2. The active dispute line becomes `retailer_response_received`.
3. The retailer reply remains saved in `dispute_messages`.
4. The supervisor page resolves the retailer outcome as accepted.
5. The existing `Accept final refund outcome` button becomes enabled when its existing prerequisites are satisfied.
6. The existing supervisor action advances legally:
   `raised → under_review → approved_refund → awaiting_refund_credit`.
7. No `raised → awaiting_refund_credit` transition is attempted by the operator/importer RPC.
8. `still_waiting`, `retailer_disputed`, and `more_info_requested` behaviour is unchanged.
9. Replacement disputes are unchanged.
10. The transition guard remains active and unchanged.
11. Refund evidence / return / accounting flows remain unchanged after `awaiting_refund_credit`.
12. Existing auth, operator/importer scope, and fail-closed checks remain intact.

## 9. Scope freeze

The implementation is complete when one corrective migration removes only the parent-dispute status advancement from `operator_update_dispute_retailer_update(...)` and the regression proof above passes.

Any change outside that boundary requires a separate addendum and separate approval.
