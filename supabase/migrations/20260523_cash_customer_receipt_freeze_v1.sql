BEGIN;

-- Cash Posting Workbench: customer/importer IN freeze + validation.
-- Additive only. No Sage API call. No live posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN
    CREATE TABLE public.cash_posting_snapshots (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      active boolean NOT NULL DEFAULT true,
      posting_category text NOT NULL,
      source_type text NOT NULL,
      source_id uuid NOT NULL,
      statement_line_id uuid,
      order_id uuid,
      order_ref text,
      counterparty_type text,
      counterparty_id uuid,
      counterparty_name text,
      sage_contact_id text,
      sage_contact_name text,
      sage_bank_account_id text,
      amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
      posting_date date NOT NULL DEFAULT CURRENT_DATE,
      short_reference text NOT NULL,
      idempotency_key text NOT NULL,
      request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      internal_reference_json jsonb NOT NULL DEFAULT '{}'::jsonb,
      freeze_status text NOT NULL DEFAULT 'frozen',
      validation_status text NOT NULL DEFAULT 'validated',
      validation_errors jsonb NOT NULL DEFAULT '[]'::jsonb,
      sage_posting_status text NOT NULL DEFAULT 'not_posted',
      sage_object_id text,
      sage_payment_on_account_id text,
      sage_response_payload jsonb,
      notes text,
      frozen_at timestamptz NOT NULL DEFAULT now(),
      validated_at timestamptz,
      created_by_staff_id uuid,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    );
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_posting_snapshots_active_idempotency
  ON public.cash_posting_snapshots (idempotency_key)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS ix_cash_posting_snapshots_source
  ON public.cash_posting_snapshots (source_type, source_id, posting_category)
  WHERE active = true;

CREATE OR REPLACE FUNCTION public.internal_cash_posting_snapshot_status_by_source_v1(
  p_source_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS TABLE (
  source_id uuid,
  posting_category text,
  snapshot_id uuid,
  workbench_status text,
  blocker text,
  selectable boolean,
  validation_status text,
  sage_posting_status text,
  amount_gbp numeric,
  short_reference text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  RETURN QUERY
  SELECT
    s.source_id,
    s.posting_category,
    s.id AS snapshot_id,
    CASE
      WHEN s.sage_posting_status = 'posted' THEN 'posted'
      WHEN s.validation_status = 'validated' THEN 'frozen_validated'
      WHEN s.validation_status = 'failed' THEN 'frozen_validation_failed'
      ELSE 'frozen'
    END::text AS workbench_status,
    CASE
      WHEN s.sage_posting_status = 'posted' THEN 'already posted'
      WHEN s.validation_status = 'validated' THEN 'frozen and validated; create/post action is next phase'
      WHEN jsonb_array_length(COALESCE(s.validation_errors, '[]'::jsonb)) > 0 THEN s.validation_errors::text
      ELSE NULL::text
    END AS blocker,
    false AS selectable,
    s.validation_status,
    s.sage_posting_status,
    s.amount_gbp,
    s.short_reference
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND (COALESCE(array_length(p_source_ids, 1), 0) = 0 OR s.source_id = ANY(p_source_ids));
END;
$$;

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
    SELECT DISTINCT unnest(COALESCE(p_dva_reconciliation_ids, ARRAY[]::uuid[])) AS dva_reconciliation_id
  ), cash_defaults AS (
    SELECT
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'DVA_CASH_BANK_ACCOUNT' AND sm.is_active = true) AS bank_account_id
    FROM public.sage_mapping_settings sm
  ), candidate AS (
    SELECT
      sel.dva_reconciliation_id AS selected_id,
      dr.id AS source_id,
      dsl.id AS statement_line_id,
      dsl.dva_statement_id AS statement_id,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      o.importer_id AS counterparty_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS counterparty_name,
      COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id')::text AS auth_ref,
      (to_jsonb(dsl)->>'reference_raw')::text AS reference_raw,
      COALESCE(to_jsonb(dsl)->>'statement_date', to_jsonb(dsl)->>'transaction_date')::text AS statement_date_text,
      COALESCE(to_jsonb(dsl)->>'direction', '')::text AS statement_direction,
      round(COALESCE(dr.reconciled_gbp_amount, dsl.amount_gbp_equivalent, 0)::numeric, 2) AS amount_gbp,
      pm.sage_contact_id::text AS sage_contact_id,
      pm.sage_contact_display_name::text AS sage_contact_name,
      cd.bank_account_id::text AS sage_bank_account_id,
      ('GCB-IN-' || left(COALESCE(o.order_ref::text, o.id::text), 18) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10))::text AS short_reference,
      ('cash:customer_receipt:dva_reconciliation:' || dr.id::text)::text AS idempotency_key,
      existing.id AS existing_snapshot_id
    FROM selected sel
    LEFT JOIN public.dva_reconciliation dr ON dr.id = sel.dva_reconciliation_id
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
        WHEN c.source_id IS NULL THEN 'selected source is not a DVA customer funding reconciliation'
        WHEN c.existing_snapshot_id IS NOT NULL THEN 'already frozen'
        WHEN NULLIF(trim(COALESCE(c.sage_contact_id, '')), '') IS NULL THEN 'importer/customer Sage contact mapping missing'
        WHEN NULLIF(trim(COALESCE(c.sage_bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN c.statement_direction <> 'in' THEN 'DVA funding statement line is not IN'
        WHEN c.amount_gbp <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS blocker,
      COALESCE(NULLIF(c.statement_date_text, '')::date, CURRENT_DATE) AS posting_date
    FROM candidate c
  ), inserted AS (
    INSERT INTO public.cash_posting_snapshots (
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
      p.source_id,
      p.statement_line_id,
      p.order_id,
      p.order_ref,
      'importer_customer',
      p.counterparty_id,
      p.counterparty_name,
      p.sage_contact_id,
      p.sage_contact_name,
      p.sage_bank_account_id,
      p.amount_gbp,
      p.posting_date,
      p.short_reference,
      p.idempotency_key,
      jsonb_build_object(
        'endpoint', '/contact_payments',
        'method', 'POST',
        'posting_category', 'customer_receipt_on_account',
        'contact_payment', jsonb_build_object(
          'transaction_type_id', 'CUSTOMER_RECEIPT',
          'contact_id', p.sage_contact_id,
          'bank_account_id', p.sage_bank_account_id,
          'date', p.posting_date::text,
          'total_amount', p.amount_gbp,
          'reference', p.short_reference
        )
      ),
      jsonb_build_object(
        'statement_line_id', p.statement_line_id,
        'dva_reconciliation_id', p.source_id,
        'statement_id', p.statement_id,
        'order_id', p.order_id,
        'order_ref', p.order_ref,
        'auth_ref', p.auth_ref,
        'reference_raw', p.reference_raw,
        'counterparty_type', 'importer_customer',
        'counterparty_id', p.counterparty_id,
        'counterparty_name', p.counterparty_name,
        'target_sage_contact_id', p.sage_contact_id,
        'target_sage_bank_account_id', p.sage_bank_account_id,
        'idempotency_key', p.idempotency_key
      ),
      'frozen',
      'validated',
      '[]'::jsonb,
      p_notes,
      now(),
      v_staff_id
    FROM prepared p
    WHERE p.blocker IS NULL
    RETURNING id, source_id, validation_status, short_reference, amount_gbp
  )
  SELECT
    p.selected_id AS source_id,
    COALESCE(i.id, p.existing_snapshot_id) AS snapshot_id,
    CASE
      WHEN p.existing_snapshot_id IS NOT NULL THEN 'already_frozen'
      WHEN i.id IS NOT NULL THEN 'frozen'
      ELSE 'not_frozen'
    END::text AS freeze_status,
    COALESCE(i.validation_status, CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'validated' ELSE 'not_validated' END)::text AS validation_status,
    CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'already frozen' ELSE p.blocker END AS blocker,
    COALESCE(i.short_reference, p.short_reference) AS short_reference,
    COALESCE(i.amount_gbp, p.amount_gbp) AS amount_gbp
  FROM prepared p
  LEFT JOIN inserted i ON i.source_id = p.source_id
  ORDER BY p.statement_date_text DESC NULLS LAST, p.selected_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_customer_receipt_cash_posting_v1(uuid[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_cash_posting_snapshot_status_by_source_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_customer_receipt_cash_posting_v1(uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_snapshot_status_by_source_v1(uuid[]) TO authenticated;

COMMENT ON TABLE public.cash_posting_snapshots IS 'Immutable frozen cash posting payloads for Accounting Command Centre cash workbench. Created before any Sage cash API call.';
COMMENT ON FUNCTION public.internal_freeze_customer_receipt_cash_posting_v1(uuid[], text) IS 'Freeze and validate selected customer/importer IN DVA reconciliation rows into cash_posting_snapshots. No Sage API call.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks after applying as an accounting admin user:
-- select * from public.internal_freeze_customer_receipt_cash_posting_v1(ARRAY['00000000-0000-0000-0000-000000000000']::uuid[], 'smoke');
-- select * from public.internal_cash_posting_snapshot_status_by_source_v1(ARRAY[]::uuid[]);
