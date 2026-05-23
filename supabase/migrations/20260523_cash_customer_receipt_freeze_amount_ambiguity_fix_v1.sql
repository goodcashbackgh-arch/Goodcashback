BEGIN;

-- Fix: internal_freeze_customer_receipt_cash_posting_v1 failed at runtime with
-- column reference "amount_gbp" is ambiguous.
-- Cause: RETURNS TABLE output names can conflict with unqualified/returned SQL names inside PL/pgSQL.
-- This patch renames the internal CTE/RETURNING aliases and qualifies all returned values.
-- No table/data/UI/Sage changes.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_freeze_customer_receipt_cash_posting_v1(
  p_dva_reconciliation_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  source_id uuid,
  snapshot_id uuid,
  freeze_status text,
  validation_status text,
  blocker text,
  short_reference text,
  amount_gbp numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT unnest(COALESCE(p_dva_reconciliation_ids, ARRAY[]::uuid[])) AS selected_dva_reconciliation_id
  ), cash_defaults AS (
    SELECT
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'DVA_CASH_BANK_ACCOUNT' AND sm.is_active = true) AS default_bank_account_id
    FROM public.sage_mapping_settings sm
  ), candidate AS (
    SELECT
      sel.selected_dva_reconciliation_id AS selected_id,
      dr.id AS cand_source_id,
      dsl.id AS cand_statement_line_id,
      dsl.dva_statement_id AS cand_statement_id,
      o.id AS cand_order_id,
      o.order_ref::text AS cand_order_ref,
      o.importer_id AS cand_counterparty_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS cand_counterparty_name,
      COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id')::text AS cand_auth_ref,
      (to_jsonb(dsl)->>'reference_raw')::text AS cand_reference_raw,
      COALESCE(to_jsonb(dsl)->>'statement_date', to_jsonb(dsl)->>'transaction_date')::text AS cand_statement_date_text,
      COALESCE(to_jsonb(dsl)->>'direction', '')::text AS cand_statement_direction,
      round(COALESCE(dr.reconciled_gbp_amount, dsl.amount_gbp_equivalent, 0)::numeric, 2) AS cand_amount_gbp,
      pm.sage_contact_id::text AS cand_sage_contact_id,
      pm.sage_contact_display_name::text AS cand_sage_contact_name,
      cd.default_bank_account_id::text AS cand_sage_bank_account_id,
      ('GCB-IN-' || left(COALESCE(o.order_ref::text, o.id::text), 18) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10))::text AS cand_short_reference,
      ('cash:customer_receipt:dva_reconciliation:' || dr.id::text)::text AS cand_idempotency_key,
      existing.id AS existing_snapshot_id
    FROM selected sel
    LEFT JOIN public.dva_reconciliation dr ON dr.id = sel.selected_dva_reconciliation_id
    LEFT JOIN public.dva_statement_lines dsl ON dsl.id = dr.dva_statement_line_id
    LEFT JOIN public.orders o ON o.id = dr.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    CROSS JOIN cash_defaults cd
    LEFT JOIN LATERAL (
      SELECT spm.*
      FROM public.sage_party_mappings spm
      WHERE spm.platform_party_type = 'importer_customer'
        AND spm.platform_party_id = o.importer_id
        AND spm.active = true
      ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    LEFT JOIN public.cash_posting_snapshots existing
      ON existing.active = true
     AND existing.idempotency_key = ('cash:customer_receipt:dva_reconciliation:' || dr.id::text)
  ), prepared AS (
    SELECT
      c.*,
      CASE
        WHEN c.cand_source_id IS NULL THEN 'selected source is not a DVA customer funding reconciliation'
        WHEN c.existing_snapshot_id IS NOT NULL THEN 'already frozen'
        WHEN NULLIF(trim(COALESCE(c.cand_sage_contact_id, '')), '') IS NULL THEN 'importer/customer Sage contact mapping missing'
        WHEN NULLIF(trim(COALESCE(c.cand_sage_bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN c.cand_statement_direction <> 'in' THEN 'DVA funding statement line is not IN'
        WHEN c.cand_amount_gbp <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS cand_blocker,
      COALESCE(NULLIF(c.cand_statement_date_text, '')::date, CURRENT_DATE) AS cand_posting_date
    FROM candidate c
  ), inserted AS (
    INSERT INTO public.cash_posting_snapshots AS cps (
      posting_category,
      source_type,
      source_id,
      statement_line_id,
      order_id,
      order_ref,
      counterparty_type,
      counterparty_id,
      counterparty_name,
      sage_contact_id,
      sage_contact_name,
      sage_bank_account_id,
      amount_gbp,
      posting_date,
      short_reference,
      idempotency_key,
      request_payload,
      internal_reference_json,
      freeze_status,
      validation_status,
      validation_errors,
      notes,
      validated_at,
      created_by_staff_id
    )
    SELECT
      'customer_receipt_on_account',
      'dva_reconciliation',
      p.cand_source_id,
      p.cand_statement_line_id,
      p.cand_order_id,
      p.cand_order_ref,
      'importer_customer',
      p.cand_counterparty_id,
      p.cand_counterparty_name,
      p.cand_sage_contact_id,
      p.cand_sage_contact_name,
      p.cand_sage_bank_account_id,
      p.cand_amount_gbp,
      p.cand_posting_date,
      p.cand_short_reference,
      p.cand_idempotency_key,
      jsonb_build_object(
        'endpoint', '/contact_payments',
        'method', 'POST',
        'posting_category', 'customer_receipt_on_account',
        'contact_payment', jsonb_build_object(
          'transaction_type_id', 'CUSTOMER_RECEIPT',
          'contact_id', p.cand_sage_contact_id,
          'bank_account_id', p.cand_sage_bank_account_id,
          'date', p.cand_posting_date::text,
          'total_amount', p.cand_amount_gbp,
          'reference', p.cand_short_reference
        )
      ),
      jsonb_build_object(
        'statement_line_id', p.cand_statement_line_id,
        'dva_reconciliation_id', p.cand_source_id,
        'statement_id', p.cand_statement_id,
        'order_id', p.cand_order_id,
        'order_ref', p.cand_order_ref,
        'auth_ref', p.cand_auth_ref,
        'reference_raw', p.cand_reference_raw,
        'counterparty_type', 'importer_customer',
        'counterparty_id', p.cand_counterparty_id,
        'counterparty_name', p.cand_counterparty_name,
        'target_sage_contact_id', p.cand_sage_contact_id,
        'target_sage_bank_account_id', p.cand_sage_bank_account_id,
        'idempotency_key', p.cand_idempotency_key
      ),
      'frozen',
      'validated',
      '[]'::jsonb,
      p_notes,
      now(),
      v_staff_id
    FROM prepared p
    WHERE p.cand_blocker IS NULL
    RETURNING
      cps.id AS inserted_snapshot_id,
      cps.source_id AS inserted_source_id,
      cps.validation_status AS inserted_validation_status,
      cps.short_reference AS inserted_short_reference,
      cps.amount_gbp AS inserted_amount_gbp
  )
  SELECT
    p.selected_id AS source_id,
    COALESCE(i.inserted_snapshot_id, p.existing_snapshot_id) AS snapshot_id,
    CASE
      WHEN p.existing_snapshot_id IS NOT NULL THEN 'already_frozen'
      WHEN i.inserted_snapshot_id IS NOT NULL THEN 'frozen'
      ELSE 'not_frozen'
    END::text AS freeze_status,
    COALESCE(i.inserted_validation_status, CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'validated' ELSE 'not_validated' END)::text AS validation_status,
    CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'already frozen' ELSE p.cand_blocker END AS blocker,
    COALESCE(i.inserted_short_reference, p.cand_short_reference) AS short_reference,
    COALESCE(i.inserted_amount_gbp, p.cand_amount_gbp) AS amount_gbp
  FROM prepared p
  LEFT JOIN inserted i ON i.inserted_source_id = p.cand_source_id
  ORDER BY p.cand_statement_date_text DESC NULLS LAST, p.selected_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_customer_receipt_cash_posting_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_customer_receipt_cash_posting_v1(uuid[], text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
