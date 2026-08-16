BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Shipment Batch Undo & Release Control v1
-- Authority:
--   docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- Scope is intentionally limited to:
--   * governed Shipment Batch Undo;
--   * mutable progressed-adjustment housekeeping required by that Undo;
--   * parent-batch row-lock hardening of the four non-Groupage writers expressly
--     authorised by the corrected addendum.
--
-- GROUPAGE PROTECTED BOUNDARY:
--   Groupage is read-only to this build. No Groupage function, permission,
--   workflow, review cascade, POD behaviour, status logic or UI is changed here.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.shipper_groupage_movement_batches') IS NULL
     OR to_regclass('public.shipping_documents') IS NULL
     OR to_regclass('public.shipping_cost_allocations') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.shipper_final_export_evidence_documents') IS NULL
     OR to_regclass('public.invoice_adjustment_consumption_ledger') IS NULL
     OR to_regclass('public.shipper_export_evidence_completion_fields') IS NULL
  THEN
    RAISE EXCEPTION 'Shipment Batch Undo prerequisite relation missing.';
  END IF;

  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.shipper_block_shipment_line_membership_mutation_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Shipment Batch Undo prerequisite function missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.shipper_undo_shipment_batch_v1(
  p_shipment_batch_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch public.shipper_shipment_batches%ROWTYPE;
  v_reason text;
  v_package record;
  v_active_package_count integer := 0;
  v_deactivated_package_count integer := 0;
  v_deactivated_line_count integer := 0;
  v_adjustment_rebuilt_count integer := 0;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipment batch undo requires auth.uid()';
  END IF;

  IF p_shipment_batch_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch id is required.';
  END IF;

  v_reason := NULLIF(BTRIM(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Undo reason is required.';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.*
    INTO v_batch
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch.id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found.';
  END IF;

  IF v_batch.shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Shipment batch does not belong to this shipper.';
  END IF;

  IF v_batch.status IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Shipment batch can no longer be undone at status: %', v_batch.status;
  END IF;

  PERFORM 1
  FROM public.shipper_shipment_batch_packages p
  WHERE p.shipment_batch_id = p_shipment_batch_id
    AND p.active = true
  ORDER BY p.order_id, p.tracking_submission_id, p.id
  FOR UPDATE;

  SELECT COUNT(*)::integer
    INTO v_active_package_count
  FROM public.shipper_shipment_batch_packages p
  WHERE p.shipment_batch_id = p_shipment_batch_id
    AND p.active = true;

  IF COALESCE(v_active_package_count, 0) = 0 THEN
    RAISE EXCEPTION 'Shipment batch has no active packages to release.';
  END IF;

  FOR v_package IN
    SELECT p.order_id, p.tracking_submission_id
    FROM public.shipper_shipment_batch_packages p
    WHERE p.shipment_batch_id = p_shipment_batch_id
      AND p.active = true
    ORDER BY p.order_id, p.tracking_submission_id, p.id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext(v_package.order_id::text));
    PERFORM pg_advisory_xact_lock(hashtext(v_package.tracking_submission_id::text));
  END LOOP;

  PERFORM 1
  FROM public.order_tracking_line_allocations a
  JOIN (
    SELECT DISTINCT e.tracking_line_allocation_id
    FROM public.shipper_shipment_batch_effective_lines_v1(p_shipment_batch_id) e
  ) effective
    ON effective.tracking_line_allocation_id = a.id
  ORDER BY a.id
  FOR UPDATE OF a;

  -- Groupage is READ ONLY here. Existing Groupage authorities are untouched.
  IF EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movement_batches gmb
    WHERE gmb.shipment_batch_id = p_shipment_batch_id
      AND gmb.active = true
  ) THEN
    RAISE EXCEPTION 'Undo blocked: shipment batch is in an active Groupage Movement. Complete the existing Groupage removal/cancellation process first.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipping_documents sd
    WHERE sd.shipment_batch_id = p_shipment_batch_id
      AND sd.active = true
  ) THEN
    RAISE EXCEPTION 'Undo blocked: an active shipping document exists for this shipment batch.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipping_cost_allocations sca
    WHERE sca.shipment_batch_id = p_shipment_batch_id
      AND sca.active = true
      AND sca.allocation_status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Undo blocked: an active approved shipping-cost allocation exists for this shipment batch.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN (
      SELECT DISTINCT e.tracking_line_allocation_id
      FROM public.shipper_shipment_batch_effective_lines_v1(p_shipment_batch_id) e
    ) effective
      ON effective.tracking_line_allocation_id = a.id
    WHERE a.locked_for_export_pack_at IS NOT NULL
       OR a.allocation_status = 'locked_for_export_pack'
  ) THEN
    RAISE EXCEPTION 'Undo blocked: one or more shipment allocations are locked for export.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines csrl
    WHERE csrl.source_shipment_batch_id = p_shipment_batch_id
      AND csrl.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Undo blocked: an active customer-sales release exists for this shipment batch.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.shipment_batch_id = p_shipment_batch_id
      AND (
        s.sage_posting_status = 'posted'
        OR (COALESCE(s.active, true) = true AND COALESCE(s.sage_posting_status, 'not_posted') <> 'voided')
      )
  ) THEN
    RAISE EXCEPTION 'Undo blocked: an active/frozen or posted accounting snapshot exists for this shipment batch.';
  END IF;

  -- Any final export evidence is a hard Undo boundary. This deliberately avoids
  -- changing the existing final-evidence review authority, including Groupage-
  -- aware review cascading/status behaviour.
  IF EXISTS (
    SELECT 1
    FROM public.shipper_final_export_evidence_documents d
    WHERE d.shipment_batch_id = p_shipment_batch_id
  ) THEN
    RAISE EXCEPTION 'Undo blocked: final export evidence exists for this shipment batch.';
  END IF;

  -- Mutable progressed rows are not blockers, but only while they remain inside
  -- the same mutability boundary used by recalculate_invoice_adjustment_consumption_v1.
  IF EXISTS (
    SELECT 1
    FROM public.invoice_adjustment_consumption_ledger l
    LEFT JOIN public.order_tracking_line_allocations a
      ON a.id = l.source_allocation_id
    WHERE l.shipment_batch_id = p_shipment_batch_id
      AND l.active = true
      AND l.outcome = 'progressed_allocated'
      AND (
        a.id IS NULL
        OR a.locked_for_export_pack_at IS NOT NULL
        OR a.allocation_status = 'locked_for_export_pack'
        OR EXISTS (
          SELECT 1
          FROM public.customer_sales_release_lines csrl
          WHERE csrl.tracking_line_allocation_id = a.id
            AND csrl.release_status = 'active'
        )
      )
  ) THEN
    RAISE EXCEPTION 'Undo blocked: mutable invoice-adjustment state has crossed an immutable export/customer-release boundary.';
  END IF;

  UPDATE public.shipper_shipment_batch_line_memberships m
  SET active = false
  WHERE m.shipment_batch_id = p_shipment_batch_id
    AND m.active = true;
  GET DIAGNOSTICS v_deactivated_line_count = ROW_COUNT;

  UPDATE public.shipper_shipment_batch_packages p
  SET active = false,
      removed_at = now(),
      removed_by_shipper_user_id = v_shipper_user_id,
      remove_reason = v_reason
  WHERE p.shipment_batch_id = p_shipment_batch_id
    AND p.active = true;
  GET DIAGNOSTICS v_deactivated_package_count = ROW_COUNT;

  -- Supersede/rebuild only mutable progressed rows. Financial quantities and
  -- source identities are preserved; only the stale Shipment Batch reference is
  -- removed. Terminal outcomes are not selected or changed.
  WITH affected AS (
    SELECT l.*
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id = p_shipment_batch_id
      AND l.active = true
      AND l.outcome = 'progressed_allocated'
    ORDER BY l.id
    FOR UPDATE
  ), superseded AS (
    UPDATE public.invoice_adjustment_consumption_ledger l
    SET active = false,
        outcome = 'superseded',
        superseded_at = now()
    FROM affected a
    WHERE l.id = a.id
    RETURNING a.*
  ), rebuilt AS (
    INSERT INTO public.invoice_adjustment_consumption_ledger (
      invoice_adjustment_basis_id,
      supplier_invoice_id,
      supplier_invoice_line_id,
      source_allocation_id,
      tracking_submission_id,
      shipment_batch_id,
      qty_consumed,
      base_value_consumed_gbp,
      discount_consumed_gbp,
      delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,
      outcome,
      reason,
      active,
      created_by_staff_id,
      created_by_operator_id
    )
    SELECT
      s.invoice_adjustment_basis_id,
      s.supplier_invoice_id,
      s.supplier_invoice_line_id,
      s.source_allocation_id,
      s.tracking_submission_id,
      NULL::uuid,
      s.qty_consumed,
      s.base_value_consumed_gbp,
      s.discount_consumed_gbp,
      s.delivery_consumed_gbp,
      s.chargeable_adjusted_goods_basis_gbp,
      'progressed_allocated',
      'Progressed allocation rebuilt after governed Shipment Batch Undo.',
      true,
      s.created_by_staff_id,
      s.created_by_operator_id
    FROM superseded s
    RETURNING id
  )
  SELECT COUNT(*)::integer
    INTO v_adjustment_rebuilt_count
  FROM rebuilt;

  UPDATE public.shipper_shipment_batches b
  SET status = 'voided',
      voided_at = now(),
      voided_by_shipper_user_id = v_shipper_user_id,
      void_reason = v_reason
  WHERE b.id = p_shipment_batch_id
    AND b.status = 'created';

  RETURN jsonb_build_object(
    'ok', true,
    'shipment_batch_id', p_shipment_batch_id,
    'status', 'voided',
    'released_package_count', v_deactivated_package_count,
    'deactivated_line_count', v_deactivated_line_count,
    'rebuilt_progressed_adjustment_count', v_adjustment_rebuilt_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_undo_shipment_batch_v1(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shipper_undo_shipment_batch_v1(uuid,text) TO authenticated;

-- =============================================================================
-- Authorised non-Groupage writer hardening.
-- Existing function bodies are preserved; only the parent Shipment Batch row
-- lock/status boundary authorised by the addendum is added. Existing ACLs are
-- deliberately not changed by this migration.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.shipper_update_shipment_batch_header_v1(
  p_shipment_batch_id uuid,
  p_booking_ref text,
  p_shipment_cutoff_at timestamptz DEFAULT NULL,
  p_dispatched_at timestamptz DEFAULT NULL,
  p_box_count integer DEFAULT NULL,
  p_container_ref text DEFAULT NULL,
  p_bol_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_shipper_id uuid;
  v_status text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: update shipment batch requires auth.uid()';
  END IF;

  IF p_shipment_batch_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch id is required.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_booking_ref, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Booking reference is required.';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.shipper_id, b.status
    INTO v_batch_shipper_id, v_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found.';
  END IF;

  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Shipment batch does not belong to this shipper.';
  END IF;

  IF v_status IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Shipment batch can no longer be edited at this status: %', v_status;
  END IF;

  UPDATE public.shipper_shipment_batches
  SET
    booking_ref = BTRIM(p_booking_ref),
    shipment_cutoff_at = p_shipment_cutoff_at,
    dispatched_at = p_dispatched_at,
    box_count = p_box_count,
    notes = NULLIF(BTRIM(COALESCE(p_notes, '')), '')
  WHERE id = p_shipment_batch_id;

  -- Deliberately do not update container_ref or bol_ref here.
  -- Those belong to the master-shipment/export-evidence lane.

  RETURN p_shipment_batch_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.shipper_save_export_evidence_completion_fields_v1(
  p_shipment_batch_id uuid,
  p_mbl_bol_sea_waybill_ref text DEFAULT NULL,
  p_container_number text DEFAULT NULL,
  p_seal_number text DEFAULT NULL,
  p_vessel_voyage text DEFAULT NULL,
  p_port_of_loading text DEFAULT NULL,
  p_port_of_discharge text DEFAULT NULL,
  p_place_of_delivery text DEFAULT NULL,
  p_export_shipment_date date DEFAULT NULL,
  p_final_package_confirmation text DEFAULT NULL,
  p_authorised_name text DEFAULT NULL,
  p_signature_stamp_confirmation_yn boolean DEFAULT false,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_shipper_id uuid;
  v_status text;
  v_completion_status text;
  v_row_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: export evidence completion requires auth.uid()';
  END IF;

  IF p_shipment_batch_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch id is required.';
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.shipper_id, b.status
    INTO v_batch_shipper_id, v_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found.';
  END IF;

  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Shipment batch does not belong to this shipper.';
  END IF;

  IF v_status IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Export evidence fields cannot be edited for shipment batch status: %', v_status;
  END IF;

  v_completion_status := CASE
    WHEN NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_container_number, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_seal_number, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), '') IS NOT NULL
     AND p_export_shipment_date IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_final_package_confirmation, '')), '') IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_authorised_name, '')), '') IS NOT NULL
     AND COALESCE(p_signature_stamp_confirmation_yn, false) = true
    THEN 'completion_fields_ready'
    ELSE 'completion_fields_draft'
  END;

  INSERT INTO public.shipper_export_evidence_completion_fields (
    shipment_batch_id,
    shipper_id,
    mbl_bol_sea_waybill_ref,
    container_number,
    seal_number,
    vessel_voyage,
    port_of_loading,
    port_of_discharge,
    place_of_delivery,
    export_shipment_date,
    final_package_confirmation,
    authorised_name,
    signature_stamp_confirmation_yn,
    notes,
    completion_status,
    created_by_shipper_user_id,
    updated_by_shipper_user_id
  ) VALUES (
    p_shipment_batch_id,
    v_shipper_id,
    NULLIF(BTRIM(COALESCE(p_mbl_bol_sea_waybill_ref, '')), ''),
    NULLIF(BTRIM(COALESCE(p_container_number, '')), ''),
    NULLIF(BTRIM(COALESCE(p_seal_number, '')), ''),
    NULLIF(BTRIM(COALESCE(p_vessel_voyage, '')), ''),
    NULLIF(BTRIM(COALESCE(p_port_of_loading, '')), ''),
    NULLIF(BTRIM(COALESCE(p_port_of_discharge, '')), ''),
    NULLIF(BTRIM(COALESCE(p_place_of_delivery, '')), ''),
    p_export_shipment_date,
    NULLIF(BTRIM(COALESCE(p_final_package_confirmation, '')), ''),
    NULLIF(BTRIM(COALESCE(p_authorised_name, '')), ''),
    COALESCE(p_signature_stamp_confirmation_yn, false),
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''),
    v_completion_status,
    v_shipper_user_id,
    v_shipper_user_id
  )
  ON CONFLICT (shipment_batch_id)
  DO UPDATE SET
    mbl_bol_sea_waybill_ref = EXCLUDED.mbl_bol_sea_waybill_ref,
    container_number = EXCLUDED.container_number,
    seal_number = EXCLUDED.seal_number,
    vessel_voyage = EXCLUDED.vessel_voyage,
    port_of_loading = EXCLUDED.port_of_loading,
    port_of_discharge = EXCLUDED.port_of_discharge,
    place_of_delivery = EXCLUDED.place_of_delivery,
    export_shipment_date = EXCLUDED.export_shipment_date,
    final_package_confirmation = EXCLUDED.final_package_confirmation,
    authorised_name = EXCLUDED.authorised_name,
    signature_stamp_confirmation_yn = EXCLUDED.signature_stamp_confirmation_yn,
    notes = EXCLUDED.notes,
    completion_status = EXCLUDED.completion_status,
    updated_by_shipper_user_id = v_shipper_user_id,
    updated_at = now()
  RETURNING id INTO v_row_id;

  RETURN v_row_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.shipper_submit_shipping_document_v1(
  p_shipment_batch_id uuid,
  p_document_kind text,
  p_document_ref text,
  p_document_date date,
  p_currency_code text,
  p_total_amount numeric,
  p_file_url text,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_importer_id uuid;
  v_existing public.shipping_documents%ROWTYPE;
  v_document_id uuid;
  v_next_version integer;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: submit shipping document requires auth.uid()';
  END IF;

  IF p_document_kind NOT IN ('shipper_invoice','shipper_receipt','supporting_charge_document') THEN
    RAISE EXCEPTION 'Choose a valid shipping document type.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Shipping document file is required.';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.importer_id INTO v_importer_id
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
    AND b.shipper_id = v_shipper_id
    AND b.status <> 'voided'
  FOR UPDATE;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found for this shipper, or batch is voided.';
  END IF;

  SELECT * INTO v_existing
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id
    AND sd.active = true
  ORDER BY sd.created_at DESC LIMIT 1;

  IF v_existing.id IS NOT NULL AND v_existing.review_status = 'accepted_current' THEN
    RAISE EXCEPTION 'Supervisor has accepted the current shipping charge document for this batch. Request resubmission instead of replacing it.';
  END IF;

  SELECT COALESCE(MAX(sd.version_no), 0) + 1 INTO v_next_version
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.shipping_documents
       SET active = false,
           review_status = 'superseded',
           superseded_at = now(),
           updated_at = now()
     WHERE shipment_batch_id = p_shipment_batch_id
       AND active = true;
  END IF;

  INSERT INTO public.shipping_documents (
    shipment_batch_id, shipper_id, importer_id, uploaded_by_shipper_user_id,
    document_kind, document_ref, document_date, currency_code, total_amount,
    file_url, ocr_status, review_status, notes, version_no, active
  ) VALUES (
    p_shipment_batch_id, v_shipper_id, v_importer_id, v_shipper_user_id,
    p_document_kind, NULLIF(BTRIM(COALESCE(p_document_ref, '')), ''), p_document_date,
    UPPER(NULLIF(BTRIM(COALESCE(p_currency_code, '')), '')), p_total_amount,
    BTRIM(p_file_url), 'not_started', 'uploaded_pending_ocr',
    NULLIF(BTRIM(COALESCE(p_notes, '')), ''), v_next_version, true
  ) RETURNING id INTO v_document_id;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.shipping_documents
       SET replaced_by_document_id = v_document_id,
           updated_at = now()
     WHERE id = v_existing.id;
  END IF;

  RETURN v_document_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.shipper_submit_final_export_evidence_v1(
  p_shipment_batch_id uuid,
  p_document_kind text,
  p_document_ref text DEFAULT NULL,
  p_file_url text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_batch_shipper_id uuid;
  v_batch_status text;
  v_completion_status text;
  v_document_id uuid;
BEGIN
  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid() AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.shipper_id, b.status
    INTO v_batch_shipper_id, v_batch_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Shipment batch not found.';
  END IF;

  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Shipment batch does not belong to this shipper.';
  END IF;

  IF v_batch_status IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Final export evidence cannot be submitted for shipment batch status: %', v_batch_status;
  END IF;

  SELECT f.completion_status INTO v_completion_status
  FROM public.shipper_export_evidence_completion_fields f
  WHERE f.shipment_batch_id = p_shipment_batch_id;

  IF COALESCE(v_completion_status,'completion_fields_draft') <> 'completion_fields_ready' THEN
    RAISE EXCEPTION 'Complete and save final shipment/COS fields before uploading final export evidence.';
  END IF;

  INSERT INTO public.shipper_final_export_evidence_documents (
    shipment_batch_id, shipper_id, document_kind, document_ref, file_url, notes, review_status, created_by_shipper_user_id
  ) VALUES (
    p_shipment_batch_id, v_shipper_id, p_document_kind, NULLIF(BTRIM(COALESCE(p_document_ref,'')),''), BTRIM(COALESCE(p_file_url,'')), NULLIF(BTRIM(COALESCE(p_notes,'')),''), 'submitted_for_review', v_shipper_user_id
  ) RETURNING id INTO v_document_id;

  RETURN v_document_id;
END;
$$;

-- Installation postflight: protect the exact-line mutation authority and the new
-- Undo execution boundary. Protected Groupage definition/ACL proof is performed
-- by the governed postflight file; this migration never replaces Groupage code.
DO $postflight$
DECLARE
  v_trigger_md5 text;
BEGIN
  IF to_regprocedure('public.shipper_undo_shipment_batch_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Shipment Batch Undo RPC was not installed.';
  END IF;

  SELECT md5(pg_get_functiondef('public.shipper_block_shipment_line_membership_mutation_v1()'::regprocedure))
    INTO v_trigger_md5;

  IF v_trigger_md5 IS DISTINCT FROM 'c56d6a1a2b2c1bf0ef751a07e3b33ff2' THEN
    RAISE EXCEPTION 'Protected shipment-line mutation authority changed.';
  END IF;

  IF has_function_privilege('anon', 'public.shipper_undo_shipment_batch_v1(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anon must not execute Shipment Batch Undo.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.shipper_undo_shipment_batch_v1(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role must execute Shipment Batch Undo.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
