# Canonical Settlement Post-Funding FX Clarification v1

Status: locked implementation clarification.

This clarification controls where the Canonical Settlement Classification and Incremental Resolution Addendum v1 could otherwise be read as requiring a second physical statement-line allocation.

## Rule

Receipt-stage FX/card difference remains recorded through the existing confirmed `dva_statement_line_allocations` lane.

A later difference created only after the final customer sale value becomes known is different. Where the physical inbound statement line is already fully consumed by order funding plus its original residual classification, a supervisor must not create another statement-line allocation for the same amount. That would double-consume immutable bank evidence.

The later supervisor choice is therefore an audited order-level settlement classification linked to:

- the original order;
- the importer;
- the canonical order-attributed receipt position;
- the final customer sale value;
- the staff member, reason, timestamp and reversal history.

It may be classified as customer credit, post-funding FX/card adjustment, or a split. Customer credit creates a linked `importer_credit_ledger` row. The post-funding FX/card adjustment does not create customer credit and does not consume the statement line again.

## Canonical equation

```text
gross positive difference
  = confirmed customer credit
  + receipt-stage FX/card allocation
  + post-funding FX/card adjustment
  + remaining unresolved
```

## Guardrail

A post-funding FX/card adjustment is not permission to infer FX. It requires an explicit supervisor decision and reason. Physical statement evidence, original funding, existing allocations, Sage and VAT records remain unchanged until their separately governed posting/reversal stages act.
