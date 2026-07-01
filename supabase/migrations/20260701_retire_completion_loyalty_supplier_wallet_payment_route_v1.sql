BEGIN;

-- Retire the separate completion-loyalty supplier-wallet payment route.
-- Contract: docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md
--
-- Supplier AP settlement must flow through DVA/card/wallet statement-line
-- allocation -> cash posting workbench -> freeze/batch -> Sage. The retired
-- CLSP route bypassed statement-line allocation provenance and could credit the
-- wrong Sage bank account for split-funded supplier AP settlement.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DROP FUNCTION IF EXISTS public.test_completion_loyalty_supplier_wallet_payment_candidates_v1();
DROP FUNCTION IF EXISTS public.staff_create_completion_loyalty_supplier_wallet_cash_batch_v1(uuid[], text);
DROP FUNCTION IF EXISTS public.internal_completion_loyalty_supplier_wallet_payment_candidates_v1(text, integer, integer);
DROP FUNCTION IF EXISTS public.internal_completion_loyalty_supplier_wallet_payment_candidates_(text, integer, integer);

CREATE OR REPLACE FUNCTION public.trg_block_retired_completion_loyalty_supplier_wallet_cash_route_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF COALESCE(NEW.source_type, '') = 'completion_loyalty_supplier_wallet_payment'
     OR COALESCE(NEW.posting_category, '') = 'completion_loyalty_supplier_wallet_payment'
     OR COALESCE(NEW.idempotency_key, '') LIKE 'completion-loyalty-supplier-wallet:%'
  THEN
    RAISE EXCEPTION
      'Retired route: completion-loyalty supplier-wallet payment must use statement-line allocation and cash posting workbench source-bank split.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS block_retired_completion_loyalty_supplier_wallet_cash_route_v1
  ON public.cash_posting_snapshots;

CREATE TRIGGER block_retired_completion_loyalty_supplier_wallet_cash_route_v1
BEFORE INSERT OR UPDATE OF source_type, posting_category, idempotency_key
ON public.cash_posting_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.trg_block_retired_completion_loyalty_supplier_wallet_cash_route_v1();

COMMENT ON FUNCTION public.trg_block_retired_completion_loyalty_supplier_wallet_cash_route_v1() IS
'Blocks new cash posting snapshots for the retired completion-loyalty supplier-wallet shortcut. Use DVA/card/wallet statement-line allocations with source-specific bank mapping instead.';

NOTIFY pgrst, 'reload schema';

COMMIT;
