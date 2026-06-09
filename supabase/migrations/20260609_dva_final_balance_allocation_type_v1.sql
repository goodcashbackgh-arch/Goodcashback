BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- DVA/card final-balance allocation type v1.
-- Contract sources:
-- docs/governing-pack/ui/FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md
-- docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md
--
-- Purpose:
-- Add final_balance_payment as a first-class allocation type on the existing
-- DVA/card statement-line allocation layer. This does not use the old
-- staff_reconcile_dva_line_to_order accepted-estimate funding path.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_line_allocations';
  END IF;
END $$;

ALTER TABLE public.dva_statement_line_allocations
  DROP CONSTRAINT IF EXISTS dva_statement_line_allocations_allocation_type_check;

ALTER TABLE public.dva_statement_line_allocations
  ADD CONSTRAINT dva_statement_line_allocations_allocation_type_check
  CHECK ((allocation_type)::text = ANY ((ARRAY[
    'supplier_invoice'::varchar,
    'retailer_refund'::varchar,
    'exception_hold'::varchar,
    'not_charged_closure'::varchar,
    'fx_card_difference'::varchar,
    'bank_fee'::varchar,
    'unmatched_hold'::varchar,
    'final_balance_payment'::varchar
  ])::text[]));

ALTER TABLE public.dva_statement_line_allocations
  DROP CONSTRAINT IF EXISTS dva_statement_line_allocations_target_check;

ALTER TABLE public.dva_statement_line_allocations
  ADD CONSTRAINT dva_statement_line_allocations_target_check
  CHECK (
    (
      allocation_type = 'supplier_invoice'
      AND supplier_invoice_id IS NOT NULL
      AND dispute_id IS NULL
    )
    OR (
      allocation_type IN ('retailer_refund', 'exception_hold', 'not_charged_closure')
      AND dispute_id IS NOT NULL
    )
    OR (
      allocation_type = 'final_balance_payment'
      AND order_id IS NOT NULL
      AND supplier_invoice_id IS NULL
      AND dispute_id IS NULL
    )
    OR (
      allocation_type IN ('fx_card_difference', 'bank_fee', 'unmatched_hold')
      AND supplier_invoice_id IS NULL
      AND dispute_id IS NULL
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS dva_statement_line_allocations_active_final_balance_once
  ON public.dva_statement_line_allocations(dva_statement_line_id, order_id, allocation_type)
  WHERE allocation_type = 'final_balance_payment'
    AND order_id IS NOT NULL
    AND allocation_status <> 'reversed';

COMMENT ON TABLE public.dva_statement_line_allocations IS
'Allocation detail for one real DVA/card/bank statement line across supplier invoices, refund disputes, exception holds, final-balance payments, FX/card differences, bank fees, or unmatched holds.';

COMMENT ON COLUMN public.dva_statement_line_allocations.allocation_type IS
'Classifies the allocation: supplier invoice, retailer refund, exception hold, not charged closure, final balance payment, FX/card difference, bank fee, or unmatched hold.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks after execution:
-- select conname, pg_get_constraintdef(oid)
-- from pg_constraint
-- where conrelid = 'public.dva_statement_line_allocations'::regclass
--   and conname in (
--     'dva_statement_line_allocations_allocation_type_check',
--     'dva_statement_line_allocations_target_check'
--   );
