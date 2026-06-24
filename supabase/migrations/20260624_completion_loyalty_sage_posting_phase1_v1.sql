BEGIN;

-- Completion loyalty Sage posting phase 1.
-- Backend foundation only: dedicated posting groups/steps/logs plus controlled materialisation
-- for applied-loyalty customer settlement. No live Sage API call is made by this migration.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.order_funding_events') IS NULL THEN RAISE EXCEPTION 'Missing public.order_funding_events'; END IF;
  IF to_regclass('public.importer_credit_ledger') IS NULL THEN RAISE EXCEPTION 'Missing public.importer_credit_ledger'; END IF;
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.importers') IS NULL THEN RAISE EXCEPTION 'Missing public.importers'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_mapping_settings'; END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_party_mappings'; END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.cash_posting_snapshots'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.completion_loyalty_sage_posting_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_group_ref text NOT NULL UNIQUE,
  posting_group_type text NOT NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE RESTRICT,
  order_ref text,
  importer_id uuid REFERENCES public.importers(id) ON DELETE RESTRICT,
  order_funding_event_id uuid REFERENCES public.order_funding_events(id) ON DELETE RESTRICT,
  loyalty_match_id uuid,
  source_credit_ledger_id uuid REFERENCES public.importer_credit_ledger(id) ON DELETE RESTRICT,
  debit_ledger_id uuid REFERENCES public.importer_credit_ledger(id) ON DELETE RESTRICT,
  target_sage_invoice_snapshot_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  target_sage_invoice_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  target_allocation_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  posting_date date,
  status text NOT NULL DEFAULT 'draft',
  blocker text,
  request_context_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  approved_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  approved_at timestamptz,
  posted_at timestamptz,
  reversed_at timestamptz,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT completion_loyalty_sage_posting_group_type_chk CHECK (posting_group_type IN ('completion_loyalty_applied_settlement','completion_loyalty_internal_transfer_journal')),
  CONSTRAINT completion_loyalty_sage_posting_status_chk CHECK (status IN ('draft','blocked','locally_validated','admin_approved','posting_to_sage','partially_posted_needs_review','posted_to_sage','failed_retryable','failed_terminal','cancelled','reversal_required','reversed')),
  CONSTRAINT completion_loyalty_sage_posting_amount_chk CHECK (amount_gbp >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS completion_loyalty_sage_groups_one_active_applied_event_uidx
  ON public.completion_loyalty_sage_posting_groups(order_funding_event_id)
  WHERE active = true
    AND posting_group_type = 'completion_loyalty_applied_settlement'
    AND status NOT IN ('cancelled','reversed');

CREATE INDEX IF NOT EXISTS idx_completion_loyalty_sage_groups_status
  ON public.completion_loyalty_sage_posting_groups(posting_group_type, status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.completion_loyalty_sage_posting_steps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_group_id uuid NOT NULL REFERENCES public.completion_loyalty_sage_posting_groups(id) ON DELETE CASCADE,
  step_type text NOT NULL,
  source_table text,
  source_id uuid,
  endpoint_path text NOT NULL,
  method text NOT NULL DEFAULT 'POST',
  idempotency_key text NOT NULL UNIQUE,
  request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_payload_hash text,
  response_payload jsonb,
  sage_object_type text,
  sage_object_id text,
  sage_reference text,
  status text NOT NULL DEFAULT 'draft',
  retry_count integer NOT NULL DEFAULT 0,
  last_error text,
  posted_at timestamptz,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT completion_loyalty_sage_step_type_chk CHECK (step_type IN ('loyalty_customer_receipt','loyalty_customer_allocation','loyalty_clearing_offset','loyalty_internal_transfer_journal','loyalty_internal_transfer_out_to_in_transit','loyalty_internal_transfer_in_transit_to_dva')),
  CONSTRAINT completion_loyalty_sage_step_status_chk CHECK (status IN ('draft','blocked','locally_validated','admin_approved','posting_to_sage','posted_to_sage','failed_retryable','failed_terminal','cancelled','reversal_required','reversed')),
  CONSTRAINT completion_loyalty_sage_step_method_chk CHECK (method IN ('POST'))
);

CREATE INDEX IF NOT EXISTS idx_completion_loyalty_sage_steps_group
  ON public.completion_loyalty_sage_posting_steps(posting_group_id, step_type);

CREATE TABLE IF NOT EXISTS public.completion_loyalty_sage_posting_step_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  posting_group_id uuid REFERENCES public.completion_loyalty_sage_posting_groups(id) ON DELETE CASCADE,
  posting_step_id uuid REFERENCES public.completion_loyalty_sage_posting_steps(id) ON DELETE CASCADE,
  log_type text NOT NULL,
  message text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.completion_loyalty_sage_posting_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.completion_loyalty_sage_posting_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.completion_loyalty_sage_posting_step_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS completion_loyalty_sage_groups_staff_select ON public.completion_loyalty_sage_posting_groups;
CREATE POLICY completion_loyalty_sage_groups_staff_select
ON public.completion_loyalty_sage_posting_groups
FOR SELECT TO authenticated
USING (public.is_active_staff());

DROP POLICY IF EXISTS completion_loyalty_sage_steps_staff_select ON public.completion_loyalty_sage_posting_steps;
CREATE POLICY completion_loyalty_sage_steps_staff_select
ON public.completion_loyalty_sage_posting_steps
FOR SELECT TO authenticated
USING (public.is_active_staff());

DROP POLICY IF EXISTS completion_loyalty_sage_step_logs_staff_select ON public.completion_loyalty_sage_posting_step_logs;
CREATE POLICY completion_loyalty_sage_step_logs_staff_select
ON public.completion_loyalty_sage_posting_step_logs
FOR SELECT TO authenticated
USING (public.is_active_staff());

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_open_customer_sales_targets_v1(
  p_order_id uuid,
  p_sage_contact_id text,
  p_amount_gbp numeric
)
RETURNS TABLE (
  target_sage_invoice_snapshot_id uuid,
  target_sage_invoice_id text,
  target_order_id uuid,
  target_order_ref text,
  target_open_amount_gbp numeric,
  allocation_amount_gbp numeric,
  sort_key text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_amount numeric(18,2) := round(COALESCE(p_amount_gbp, 0)::numeric, 2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: open customer sales targets require auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for open customer sales targets.';
  END IF;

  RETURN QUERY
  WITH targets AS (
    SELECT
      sps.id AS target_sage_invoice_snapshot_id,
      sps.sage_invoice_id::text AS target_sage_invoice_id,
      sps.order_id AS target_order_id,
      sps.order_ref::text AS target_order_ref,
      round(COALESCE(sps.amount_gbp, 0)::numeric, 2) AS invoice_amount_gbp,
      COALESCE(
        NULLIF(sps.resolved_payload->'sage_header'->>'invoice_date', ''),
        NULLIF(sps.resolved_payload->'sage_header'->>'date', ''),
        NULLIF(sps.resolved_payload->'sage_invoice'->>'date', ''),
        NULLIF(sps.resolved_payload->'invoice'->>'date', ''),
        sps.created_at::date::text,
        sps.id::text
      ) AS sort_key
    FROM public.sage_posting_snapshots sps
    WHERE sps.active = true
      AND sps.document_lane = 'customer_sales'
      AND sps.sage_posting_status = 'posted'
      AND sps.order_id = p_order_id
      AND NULLIF(trim(COALESCE(sps.sage_invoice_id, '')), '') IS NOT NULL
      AND COALESCE(sps.resolved_payload->'sage_header'->>'contact_id', sps.resolved_payload->'customer_target'->>'sage_contact_id') = p_sage_contact_id
  ), previous_request_allocations AS (
    SELECT
      artefact.value->>'artefact_id' AS target_sage_invoice_id,
      SUM(GREATEST(COALESCE((artefact.value->>'amount')::numeric, 0), 0))::numeric AS allocated_gbp
    FROM public.cash_posting_snapshots cps
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(cps.sage_allocation_request_payload->'contact_allocation'->'allocated_artefacts', '[]'::jsonb)) AS artefact(value)
    WHERE cps.active = true
      AND cps.sage_allocation_status = 'allocated'
      AND cps.order_id = p_order_id
      AND artefact.value ? 'artefact_id'
    GROUP BY artefact.value->>'artefact_id'
  ), previous_legacy_allocations AS (
    SELECT
      cps.sage_allocation_target_object_id AS target_sage_invoice_id,
      SUM(COALESCE(cps.sage_allocation_amount_gbp, 0))::numeric AS allocated_gbp
    FROM public.cash_posting_snapshots cps
    WHERE cps.active = true
      AND cps.sage_allocation_status = 'allocated'
      AND cps.order_id = p_order_id
      AND NULLIF(trim(COALESCE(cps.sage_allocation_target_object_id, '')), '') IS NOT NULL
      AND cps.sage_allocation_request_payload IS NULL
    GROUP BY cps.sage_allocation_target_object_id
  ), allocated AS (
    SELECT target_sage_invoice_id, SUM(allocated_gbp)::numeric AS allocated_gbp
    FROM (
      SELECT * FROM previous_request_allocations
      UNION ALL
      SELECT * FROM previous_legacy_allocations
    ) x
    GROUP BY target_sage_invoice_id
  ), open_targets AS (
    SELECT
      t.*,
      round(GREATEST(t.invoice_amount_gbp - COALESCE(a.allocated_gbp, 0), 0)::numeric, 2) AS open_amount_gbp
    FROM targets t
    LEFT JOIN allocated a ON a.target_sage_invoice_id = t.target_sage_invoice_id
  ), ordered AS (
    SELECT
      ot.*,
      COALESCE(SUM(ot.open_amount_gbp) OVER (
        ORDER BY ot.sort_key, ot.target_sage_invoice_snapshot_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ), 0)::numeric AS prior_open_gbp
    FROM open_targets ot
    WHERE ot.open_amount_gbp > 0
  ), allocated_targets AS (
    SELECT
      o.*,
      round(LEAST(o.open_amount_gbp, GREATEST(v_amount - o.prior_open_gbp, 0))::numeric, 2) AS allocation_amount_gbp
    FROM ordered o
  )
  SELECT
    at.target_sage_invoice_snapshot_id,
    at.target_sage_invoice_id,
    at.target_order_id,
    at.target_order_ref,
    at.open_amount_gbp AS target_open_amount_gbp,
    at.allocation_amount_gbp,
    at.sort_key
  FROM allocated_targets at
  WHERE at.allocation_amount_gbp > 0
  ORDER BY at.sort_key, at.target_sage_invoice_snapshot_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_open_customer_sales_targets_v1(uuid, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_open_customer_sales_targets_v1(uuid, text, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_materialise_completion_loyalty_applied_settlement_v1(
  p_order_funding_event_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_event record;
  v_source_credit record;
  v_debit record;
  v_order record;
  v_importer_name text;
  v_amount numeric(18,2);
  v_posting_date date;
  v_sage_contact_id text;
  v_sage_contact_name text;
  v_clearing_bank_id text;
  v_expense_ledger_id text;
  v_clearing_offset_ledger_id text;
  v_targets jsonb := '[]'::jsonb;
  v_target_snapshot_ids jsonb := '[]'::jsonb;
  v_target_sage_ids jsonb := '[]'::jsonb;
  v_target_total numeric(18,2) := 0;
  v_group_id uuid;
  v_group_ref text;
  v_status text := 'locally_validated';
  v_blocker text;
  v_receipt_payload jsonb;
  v_allocation_payload jsonb;
  v_journal_payload jsonb;
  v_contact_payment_ref text;
  v_allocation_ref text;
  v_clearing_ref text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: materialise applied loyalty settlement requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required to materialise completion loyalty Sage posting groups.';
  END IF;

  SELECT ofe.* INTO v_event
  FROM public.order_funding_events ofe
  WHERE ofe.id = p_order_funding_event_id
  FOR UPDATE;

  IF v_event.id IS NULL THEN RAISE EXCEPTION 'Order funding event not found: %', p_order_funding_event_id; END IF;
  IF v_event.event_type <> 'credit_applied' THEN RAISE EXCEPTION 'Only credit_applied events can be materialised. Found: %', v_event.event_type; END IF;

  SELECT d.* INTO v_debit
  FROM public.importer_credit_ledger d
  WHERE d.id = v_event.source_entity_id;
  IF v_debit.id IS NULL THEN RAISE EXCEPTION 'Linked debit ledger row not found for event %.', p_order_funding_event_id; END IF;

  SELECT c.* INTO v_source_credit
  FROM public.importer_credit_ledger c
  WHERE c.id = COALESCE(v_debit.source_id, v_debit.source_entity_id);
  IF v_source_credit.id IS NULL THEN RAISE EXCEPTION 'Source credit ledger row not found for event %.', p_order_funding_event_id; END IF;
  IF v_source_credit.source_type <> 'completion_loyalty_reward' THEN
    RAISE EXCEPTION 'Source credit is not completion_loyalty_reward. Found: %', v_source_credit.source_type;
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = v_event.order_id;
  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found for event %.', p_order_funding_event_id; END IF;

  SELECT COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')
  INTO v_importer_name
  FROM public.importers i
  WHERE i.id = v_order.importer_id;

  SELECT spm.sage_contact_id, spm.sage_contact_display_name
  INTO v_sage_contact_id, v_sage_contact_name
  FROM public.sage_party_mappings spm
  WHERE spm.platform_party_type = 'importer_customer'
    AND spm.platform_party_id = v_order.importer_id
    AND spm.active = true
  ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
  LIMIT 1;

  SELECT MAX(sage_external_id) FILTER (WHERE mapping_code = 'LOYALTY_SETTLEMENT_CLEARING_BANK_ACCOUNT' AND is_active = true),
         MAX(sage_external_id) FILTER (WHERE mapping_code = 'LOYALTY_REWARD_EXPENSE_LEDGER' AND is_active = true),
         MAX(sage_external_id) FILTER (WHERE mapping_code = 'LOYALTY_CLEARING_OFFSET_LEDGER_OR_BANK_LEDGER' AND is_active = true)
  INTO v_clearing_bank_id, v_expense_ledger_id, v_clearing_offset_ledger_id
  FROM public.sage_mapping_settings;

  v_amount := round(abs(COALESCE(v_event.amount_gbp, 0))::numeric, 2);
  v_posting_date := COALESCE(v_event.created_at::date, now()::date);
  v_group_ref := ('CLAS-' || left(p_order_funding_event_id::text, 8))::text;
  v_contact_payment_ref := ('LA-' || left(p_order_funding_event_id::text, 6))::text;
  v_allocation_ref := ('LA-' || left(p_order_funding_event_id::text, 6))::text;
  v_clearing_ref := ('LC-' || left(p_order_funding_event_id::text, 6))::text;

  IF v_amount <= 0 THEN v_blocker := 'applied_loyalty_amount_must_be_positive'; END IF;
  IF v_blocker IS NULL AND NULLIF(trim(COALESCE(v_sage_contact_id, '')), '') IS NULL THEN v_blocker := 'missing_importer_customer_sage_contact'; END IF;
  IF v_blocker IS NULL AND NULLIF(trim(COALESCE(v_clearing_bank_id, '')), '') IS NULL THEN v_blocker := 'missing_loyalty_settlement_clearing_bank_account_mapping'; END IF;
  IF v_blocker IS NULL AND NULLIF(trim(COALESCE(v_expense_ledger_id, '')), '') IS NULL THEN v_blocker := 'missing_loyalty_reward_expense_ledger_mapping'; END IF;
  IF v_blocker IS NULL AND NULLIF(trim(COALESCE(v_clearing_offset_ledger_id, '')), '') IS NULL THEN v_blocker := 'missing_loyalty_clearing_offset_mapping'; END IF;

  IF v_blocker IS NULL THEN
    SELECT
      COALESCE(jsonb_agg(jsonb_build_object(
        'target_sage_invoice_snapshot_id', t.target_sage_invoice_snapshot_id,
        'target_sage_invoice_id', t.target_sage_invoice_id,
        'target_order_id', t.target_order_id,
        'target_order_ref', t.target_order_ref,
        'target_open_amount_gbp', t.target_open_amount_gbp,
        'allocation_amount_gbp', t.allocation_amount_gbp,
        'sort_key', t.sort_key
      ) ORDER BY t.sort_key, t.target_sage_invoice_snapshot_id), '[]'::jsonb),
      COALESCE(jsonb_agg(to_jsonb(t.target_sage_invoice_snapshot_id) ORDER BY t.sort_key, t.target_sage_invoice_snapshot_id), '[]'::jsonb),
      COALESCE(jsonb_agg(to_jsonb(t.target_sage_invoice_id) ORDER BY t.sort_key, t.target_sage_invoice_snapshot_id), '[]'::jsonb),
      round(COALESCE(sum(t.allocation_amount_gbp), 0)::numeric, 2)
    INTO v_targets, v_target_snapshot_ids, v_target_sage_ids, v_target_total
    FROM public.internal_completion_loyalty_open_customer_sales_targets_v1(v_order.id, v_sage_contact_id, v_amount) t;

    IF v_target_total <= 0 THEN
      v_blocker := 'missing_open_posted_customer_sales_invoice';
    ELSIF v_target_total + 0.01 < v_amount THEN
      v_blocker := 'combined_open_customer_receivable_below_loyalty_amount';
    END IF;
  END IF;

  IF v_blocker IS NOT NULL THEN
    v_status := 'blocked';
  END IF;

  INSERT INTO public.completion_loyalty_sage_posting_groups (
    posting_group_ref,
    posting_group_type,
    order_id,
    order_ref,
    importer_id,
    order_funding_event_id,
    source_credit_ledger_id,
    debit_ledger_id,
    target_sage_invoice_snapshot_ids,
    target_sage_invoice_ids,
    target_allocation_json,
    amount_gbp,
    posting_date,
    status,
    blocker,
    request_context_json,
    created_by_staff_id
  ) VALUES (
    v_group_ref,
    'completion_loyalty_applied_settlement',
    v_order.id,
    v_order.order_ref::text,
    v_order.importer_id,
    v_event.id,
    v_source_credit.id,
    v_debit.id,
    v_target_snapshot_ids,
    v_target_sage_ids,
    v_targets,
    v_amount,
    v_posting_date,
    v_status,
    v_blocker,
    jsonb_build_object(
      'importer_name', v_importer_name,
      'sage_contact_id', v_sage_contact_id,
      'sage_contact_name', v_sage_contact_name,
      'loyalty_settlement_clearing_bank_account', v_clearing_bank_id,
      'loyalty_reward_expense_ledger', v_expense_ledger_id,
      'loyalty_clearing_offset_ledger_or_bank_ledger', v_clearing_offset_ledger_id,
      'notes', p_notes,
      'materialised_from', 'staff_materialise_completion_loyalty_applied_settlement_v1'
    ),
    v_staff.id
  )
  ON CONFLICT (posting_group_ref) DO UPDATE SET
    updated_at = now()
  RETURNING id INTO v_group_id;

  IF v_status = 'locally_validated' THEN
    v_receipt_payload := jsonb_build_object(
      'contact_payment', jsonb_build_object(
        'transaction_type_id', 'CUSTOMER_RECEIPT',
        'contact_id', v_sage_contact_id,
        'bank_account_id', v_clearing_bank_id,
        'date', v_posting_date::text,
        'total_amount', v_amount,
        'reference', v_contact_payment_ref
      )
    );

    v_allocation_payload := jsonb_build_object(
      'contact_allocation', jsonb_build_object(
        'contact_id', v_sage_contact_id,
        'transaction_type_id', 'CUSTOMER_ALLOCATION',
        'allocated_artefacts', (
          SELECT jsonb_agg(item ORDER BY sort_ord)
          FROM (
            SELECT
              row_number() over() AS sort_ord,
              jsonb_build_object('artefact_id', target->>'target_sage_invoice_id', 'amount', round((target->>'allocation_amount_gbp')::numeric, 2)) AS item
            FROM jsonb_array_elements(v_targets) target
            UNION ALL
            SELECT 999999, jsonb_build_object('artefact_id', '__PAYMENT_ON_ACCOUNT_ID__', 'amount', -v_amount)
          ) artefacts
        )
      )
    );

    v_journal_payload := jsonb_build_object(
      'journal', jsonb_build_object(
        'date', v_posting_date::text,
        'reference', v_clearing_ref,
        'description', ('Completion loyalty clearing offset · ' || COALESCE(v_order.order_ref::text, v_order.id::text)),
        'show_payments_allocations', false,
        'journal_lines', jsonb_build_array(
          jsonb_build_object(
            'ledger_account_id', v_expense_ledger_id,
            'details', 'Completion loyalty reward expense',
            'debit', v_amount,
            'credit', 0,
            'tax_rate_id', NULL,
            'include_on_tax_return', false
          ),
          jsonb_build_object(
            'ledger_account_id', v_clearing_offset_ledger_id,
            'details', 'Completion loyalty clearing offset',
            'debit', 0,
            'credit', v_amount,
            'tax_rate_id', NULL,
            'include_on_tax_return', false
          )
        )
      )
    );

    INSERT INTO public.completion_loyalty_sage_posting_steps (
      posting_group_id, step_type, source_table, source_id, endpoint_path, method, idempotency_key, request_payload, request_payload_hash, sage_object_type, sage_reference, status
    ) VALUES
      (v_group_id, 'loyalty_customer_receipt', 'order_funding_events', v_event.id, '/contact_payments', 'POST', 'completion-loyalty-settlement-receipt:' || v_event.id::text, v_receipt_payload, md5(v_receipt_payload::text), 'contact_payment', v_contact_payment_ref, 'locally_validated'),
      (v_group_id, 'loyalty_customer_allocation', 'order_funding_events', v_event.id, '/contact_allocations', 'POST', 'completion-loyalty-settlement-allocation:' || v_event.id::text, v_allocation_payload, md5(v_allocation_payload::text), 'contact_allocation', v_allocation_ref, 'locally_validated'),
      (v_group_id, 'loyalty_clearing_offset', 'order_funding_events', v_event.id, '/journals', 'POST', 'completion-loyalty-clearing:' || v_event.id::text, v_journal_payload, md5(v_journal_payload::text), 'journal', v_clearing_ref, 'locally_validated')
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (
    posting_group_id, log_type, message, payload, created_by_staff_id
  ) VALUES (
    v_group_id,
    'materialisation',
    CASE WHEN v_status = 'locally_validated' THEN 'Applied loyalty settlement posting group materialised and locally validated.' ELSE 'Applied loyalty settlement posting group materialised as blocked.' END,
    jsonb_build_object('status', v_status, 'blocker', v_blocker, 'order_funding_event_id', v_event.id, 'target_total_gbp', v_target_total),
    v_staff.id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'posting_group_id', v_group_id,
    'posting_group_ref', v_group_ref,
    'status', v_status,
    'blocker', v_blocker,
    'amount_gbp', v_amount,
    'target_total_gbp', v_target_total
  );
EXCEPTION WHEN unique_violation THEN
  SELECT g.id, g.posting_group_ref, g.status, g.blocker
  INTO v_group_id, v_group_ref, v_status, v_blocker
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.order_funding_event_id = p_order_funding_event_id
    AND g.posting_group_type = 'completion_loyalty_applied_settlement'
    AND g.active = true
    AND g.status NOT IN ('cancelled','reversed')
  ORDER BY g.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'already_materialised', true,
    'posting_group_id', v_group_id,
    'posting_group_ref', v_group_ref,
    'status', v_status,
    'blocker', v_blocker
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_materialise_completion_loyalty_applied_settlement_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_materialise_completion_loyalty_applied_settlement_v1(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_sage_posting_groups_v1(
  p_search text DEFAULT NULL,
  p_status text DEFAULT 'all',
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  posting_group_id uuid,
  posting_group_ref text,
  posting_group_type text,
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  order_funding_event_id uuid,
  amount_gbp numeric,
  posting_date date,
  status text,
  blocker text,
  step_count bigint,
  posted_step_count bigint,
  target_sage_invoice_snapshot_ids jsonb,
  target_sage_invoice_ids jsonb,
  target_allocation_json jsonb,
  request_context_json jsonb,
  created_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'all'));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty Sage posting groups require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for loyalty Sage posting groups.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      g.id AS posting_group_id,
      g.posting_group_ref,
      g.posting_group_type,
      g.order_id,
      g.order_ref,
      g.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), g.request_context_json->>'importer_name', 'Importer/customer')::text AS importer_name,
      g.order_funding_event_id,
      g.amount_gbp,
      g.posting_date,
      g.status,
      g.blocker,
      COALESCE(count(s.id), 0)::bigint AS step_count,
      COALESCE(count(s.id) FILTER (WHERE s.status = 'posted_to_sage'), 0)::bigint AS posted_step_count,
      g.target_sage_invoice_snapshot_ids,
      g.target_sage_invoice_ids,
      g.target_allocation_json,
      g.request_context_json,
      g.created_at
    FROM public.completion_loyalty_sage_posting_groups g
    LEFT JOIN public.importers i ON i.id = g.importer_id
    LEFT JOIN public.completion_loyalty_sage_posting_steps s ON s.posting_group_id = g.id AND s.active = true
    WHERE g.active = true
    GROUP BY g.id, i.trading_name, i.company_name
  ), filtered AS (
    SELECT b.* FROM base b
    WHERE (v_status = 'all' OR lower(b.status) = v_status)
      AND (v_search IS NULL OR lower(concat_ws(' ', b.posting_group_ref, b.posting_group_type, b.order_ref, b.importer_name, b.status, b.blocker, b.order_funding_event_id::text)) LIKE '%' || v_search || '%')
  )
  SELECT f.*, count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.created_at DESC, f.posting_group_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_completion_loyalty_sage_posting_groups_v1(text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_sage_posting_groups_v1(text, text, integer, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
