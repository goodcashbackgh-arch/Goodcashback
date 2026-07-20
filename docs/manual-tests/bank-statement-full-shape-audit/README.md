# Bank statement full-shape audit

Read-only SQL diagnostics for the complete bank-statement control surface.

Scope includes main-company-bank and importer DVA/card statements; customer funding; normal and loyalty credits; overfunding and settlement credit; main-bank-to-DVA and main-bank-to-virtual-wallet loyalty transfers; supplier and shipper payments; refunds, final balances, holds, FX/card residuals, reversals; and downstream cash, Sage, VAT and journal dependencies.

## Safety

Every query is `SELECT`-only. Run the numbered files separately in Supabase SQL Editor because the result sets can be large. Do not use the outputs as a migration.

## Run order

1. Relation, column, foreign-key, index and RLS map.
2. Live dependency edges, functions and triggers.
3. Actual control vocabulary and live counts.
4. Flow population and representative examples.
5. Statement-line usage and cross-family collisions.
6. Direction and account-context control breaches.
7. Funding, credit, overfunding and loyalty provenance chains.
8. Downstream accounting, Sage and VAT object population.

These diagnostics are intended to establish the full upstream/downstream blast radius before changing funding or DVA reconciliation routing.
