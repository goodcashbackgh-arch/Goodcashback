# Hybrid Physical Receipt Build 4 — Lifecycle and Reconciliation Impact Map v1

## Governing authority

- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`
- `HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md`

## Frozen change surface

### Database replacement authorities

1. `create_replacement_child_order(uuid,uuid,uuid,text)`
   - preserve legacy caller compatibility;
   - consume one exact source dispute line;
   - where that line has physical-remedy provenance, verify the approved replacement route, approved quantity, source order and supplier-cost mode;
   - write `orders.replacement_source_dispute_line_id`;
   - link the exact remedy allocation to the child and move it through an existing guarded transition;
   - do not create replacement-of-replacement.

2. `order_has_open_child_exceptions(uuid)`
   - retain all legacy conversation blockers;
   - add unresolved physical remedy blockers;
   - add unfinished replacement-child blockers;
   - keep cancelled children blocking until the source remedy is rerouted or explicitly closed.

3. `order_reconciliation_vw`
   - preserve exact public columns and ordering;
   - count only approved, unblocked, non-superseded supplier invoice identity;
   - avoid double subtraction of a resolved dispute line whose exact supplier line already progressed;
   - never clear an over-progressed order.

### Additive database authorities

4. `order_reconciliation_anomalies_v1`
   - expose canonical over-progression;
   - expose eligible lines on non-authoritative invoices;
   - expose raw evidence exceeding declared baselines;
   - include sufficient evidence identity for controlled investigation.

5. `staff_accept_replacement_outcome_v1(uuid,uuid,text)`
   - perform the existing permitted dispute transitions, child creation, provenance linkage, dispute-line resolution and final `replaced` transition atomically;
   - require one exact remedy-linked line for a physical replacement;
   - preserve prior legacy multi-line manual replacement aggregation;
   - reject mixed physical and legacy lines;
   - authenticate the supplied active staff identity against `auth.uid()`;
   - call the hardened `create_replacement_child_order` authority rather than duplicating child creation.

### Application alignment

6. `app/internal/exceptions/[dispute_id]/actions.ts`
   - remove the parallel direct `orders` insertion path from final replacement acceptance;
   - remove separate mutation calls around child creation;
   - call `staff_accept_replacement_outcome_v1` once;
   - retain the existing read-only retailer-reply guard for immediate user feedback while the database repeats the authority check;
   - preserve current revalidation destinations and role guard.

## Protected authorities

The migration fingerprints and does not replace:

- `approve_vat_release`;
- `mark_order_accounting_release_ready`;
- `recompute_order_status`;
- physical-remedy allocation, sequence and terminal-immutability guards;
- order status-transition and content-lock guards.

No `status_transitions` row, UI label, navigation item, role grant, parent declared quantity, parent declared amount, customer-review, shipment, Sage, VAT, refund, payout or AP authority is changed.

Legacy aggregation may set the newly created replacement child’s declared quantity and value to the aggregate of its source manual lines. It must never rewrite the parent order.

## Known regression evidence

`DAY3-TRACK-1d7cfa66`:

- declared: quantity 1 / £100;
- raw eligible evidence: quantity 3 / £155;
- evidence invoice: `pending_review`, non-current;
- required canonical result: raw evidence excluded from canonical progression;
- required anomaly result: non-authoritative evidence and raw over-progression exposed.

## Deployment order

1. review and merge the alignment addendum and both Build 4 migrations;
2. apply the lifecycle/reconciliation migration;
3. apply the atomic replacement-acceptance migration;
4. run the Build 4 SQL regression;
5. deploy the application action that calls the atomic RPC;
6. run source regression and controlled final replacement acceptance;
7. verify protected fingerprints and role behaviour are unchanged.
