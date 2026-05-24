BEGIN;

-- Cash Posting Workbench contract tightening v1.
-- Additive/surgical controls only:
-- 1) Prevent new mixed IN+OUT cash posting batches.
-- 2) Normalise supplier/shipper OUT frozen payloads to the proven Sage route:
--    POST /contact_payments + VENDOR_PAYMENT + allocated_artefacts[].
-- 3) Repair existing unposted OUT snapshots/batch rows created with the older purchase_payments wording.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_batches';
  END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_snapshots';
  END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_batch_rows';
  END IF;
END $$;

ALTER TABLE public.cash_posting_batches
  ADD CONSTRAINT cash_posting_batches_no_mixed_in_out_v1
  CHECK (posting_category <> 'mixed_cash_posting') NOT VALID;

CREATE OR REPLACE FUNCTION public.internal_normalise_cash_out_request_payload_v1(
  p_posting_category text,
  p_request_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_payload jsonb := COALESCE(p_request_payload, '{}'::jsonb);
  v_contact_payment jsonb := COALESCE(v_payload->'contact_payment', '{}'::jsonb);
  v_purchase_payment jsonb := COALESCE(v_payload->'purchase_payment', '{}'::jsonb);
  v_allocation_target jsonb := COALESCE(v_payload->'allocation_target', '{}'::jsonb);
  v_source jsonb;
  v_contact_id text;
  v_bank_account_id text;
  v_date text;
  v_reference text;
  v_total_amount numeric;
  v_target_sage_object_id text;
  v_allocation_amount numeric;
BEGIN
  IF p_posting_category NOT IN ('supplier_invoice_payment', 'shipper_invoice_payment') THEN
    RETURN v_payload;
  END IF;

  v_source := CASE WHEN jsonb_typeof(v_contact_payment) = 'object' AND v_contact_payment <> '{}'::jsonb THEN v_contact_payment ELSE v_purchase_payment END;
  v_contact_id := NULLIF(trim(COALESCE(v_source->>'contact_id', '')), '');
  v_bank_account_id := NULLIF(trim(COALESCE(v_source->>'bank_account_id', '')), '');
  v_date := NULLIF(trim(COALESCE(v_source->>'date', '')), '');
  v_reference := NULLIF(trim(COALESCE(v_source->>'reference', '')), '');
  v_total_amount := COALESCE(NULLIF(v_source->>'total_amount', '')::numeric, 0);
  v_target_sage_object_id := NULLIF(trim(COALESCE(
    v_allocation_target->>'purchase_invoice_id',
    v_allocation_target->>'target_sage_object_id',
    v_contact_payment #>> '{allocated_artefacts,0,artefact_id}',
    ''
  )), '');
  v_allocation_amount := COALESCE(NULLIF(v_allocation_target->>'amount', '')::numeric, NULLIF(v_contact_payment #>> '{allocated_artefacts,0,amount}', '')::numeric, v_total_amount);

  RETURN jsonb_build_object(
    'endpoint', '/contact_payments',
    'method', 'POST',
    'posting_category', p_posting_category,
    'contact_payment', jsonb_build_object(
      'transaction_type_id', 'VENDOR_PAYMENT',
      'contact_id', v_contact_id,
      'bank_account_id', v_bank_account_id,
      'date', v_date,
      'total_amount', v_total_amount,
      'reference', v_reference,
      'allocated_artefacts', jsonb_build_array(jsonb_build_object(
        'artefact_id', v_target_sage_object_id,
        'amount', v_allocation_amount
      ))
    ),
    'cash_contract_version', 'cash_posting_workbench_v2_addendum'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.cash_posting_snapshots_normalise_out_payload_trg_v1()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.request_payload := public.internal_normalise_cash_out_request_payload_v1(NEW.posting_category, NEW.request_payload);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cash_posting_snapshots_normalise_out_payload_v1 ON public.cash_posting_snapshots;
CREATE TRIGGER trg_cash_posting_snapshots_normalise_out_payload_v1
BEFORE INSERT OR UPDATE OF request_payload, posting_category
ON public.cash_posting_snapshots
FOR EACH ROW
WHEN (NEW.posting_category IN ('supplier_invoice_payment', 'shipper_invoice_payment'))
EXECUTE FUNCTION public.cash_posting_snapshots_normalise_out_payload_trg_v1();

-- Repair existing active unposted OUT snapshots created before this tightening.
UPDATE public.cash_posting_snapshots s
SET request_payload = public.internal_normalise_cash_out_request_payload_v1(s.posting_category, s.request_payload),
    updated_at = now()
WHERE s.active = true
  AND s.posting_category IN ('supplier_invoice_payment', 'shipper_invoice_payment')
  AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted';

-- Keep unposted batch rows aligned with their frozen snapshots.
UPDATE public.cash_posting_batch_rows r
SET request_payload = s.request_payload,
    updated_at = now()
FROM public.cash_posting_snapshots s
WHERE s.id = r.snapshot_id
  AND r.active = true
  AND r.posting_category IN ('supplier_invoice_payment', 'shipper_invoice_payment')
  AND r.posting_status IN ('not_posted', 'failed_retryable')
  AND s.active = true;

COMMENT ON CONSTRAINT cash_posting_batches_no_mixed_in_out_v1 ON public.cash_posting_batches IS
'Prevents new mixed IN+OUT cash batches. Customer/importer IN receipts must not be batched with supplier/shipper OUT payments.';
COMMENT ON FUNCTION public.internal_normalise_cash_out_request_payload_v1(text, jsonb) IS
'Normalises supplier/shipper OUT frozen cash payloads to POST /contact_payments with VENDOR_PAYMENT and allocated_artefacts[].';

NOTIFY pgrst, 'reload schema';
COMMIT;
