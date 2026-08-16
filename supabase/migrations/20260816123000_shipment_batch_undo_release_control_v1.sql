BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Shipment Batch Undo & Release Control v1
-- Authority:
--   docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- Scope is intentionally limited to:
--   * governed shipment-batch undo;
--   * mutable progressed-adjustment housekeeping required by that undo;
--   * row-lock hardening of the six writers expressly named by the addendum.
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

  -- Lock active package memberships first, then take the same order/tracking
  -- advisory locks used by exact shipment creation.
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

  -- Lock the authoritative shipment allocations. For exact batches this is the
  -- immutable exact snapshot; legacy batches use the existing effective-line
  -- compatibility fallback.
  PERFORM 1
  FROM public.order_tracking_line_allocations a
  JOIN (
    SELECT DISTINCT e.tracking_line_allocation_id
    FROM public.shipper_shipment_batch_effective_lines_v1(p_shipment_batch_id) e
  ) effective
    ON effective.tracking_line_allocation_id = a.id
  ORDER BY a.id
  FOR UPDATE OF a;

  -- Current/irreversible blockers only.
  IF EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movement_batches gmb
    WHERE gmb.shipment_batch_id = p_shipment_batch_id
      AND gmb.active = true
  ) THEN
    RAISE EXCEPTION 'Undo blocked: shipment batch is in an active Groupage Movement.';
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

  IF EXISTS (
    SELECT 1
    FROM public.shipper_final_export_evidence_documents d
    WHERE d.shipment_batch_id = p_shipment_batch_id
      AND d.review_status IN ('submitted_for_review', 'accepted_current')
  ) THEN
    RAISE EXCEPTION 'Undo blocked: final export evidence is submitted for review or accepted for this shipment batch.';
  END IF;

  -- Mutable adjustment rows are not blockers. Before mutation, prove every
  -- affected progressed allocation still satisfies the same mutability boundary
  -- as recalculate_invoice_adjustment_consumption_v1.
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

  -- Deactivate exact line membership first. The protected trigger permits only
  -- active true -> false and prevents identity/value mutation or reactivation.
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

  -- Rebuild only mutable progressed adjustment rows. Values and source identity
  -- are preserved byte-for-byte; the now-stale shipment_batch_id is cleared.
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
  SELECT COUNT(*)::integer INTO v_adjustment_rebuilt_count FROM rebuilt;

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

ALTER FUNCTION public.shipper_undo_shipment_batch_v1(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.shipper_undo_shipment_batch_v1(uuid,text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.shipper_undo_shipment_batch_v1(uuid,text) TO authenticated;

-- -----------------------------------------------------------------------------
-- Writer hardening authorised by the addendum.
-- -----------------------------------------------------------------------------

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

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT b.shipper_id, b.status INTO v_batch_shipper_id, v_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch_shipper_id IS NULL THEN RAISE EXCEPTION 'Shipment batch not found.'; END IF;
  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN RAISE EXCEPTION 'Shipment batch does not belong to this shipper.'; END IF;
  IF v_status IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Shipment batch can no longer be edited at this status: %', v_status; END IF;

  UPDATE public.shipper_shipment_batches
  SET booking_ref = BTRIM(p_booking_ref),
      shipment_cutoff_at = p_shipment_cutoff_at,
      dispatched_at = p_dispatched_at,
      box_count = p_box_count,
      notes = NULLIF(BTRIM(COALESCE(p_notes, '')), '')
  WHERE id = p_shipment_batch_id;

  RETURN p_shipment_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text) TO authenticated;

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
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: export evidence completion requires auth.uid()'; END IF;
  IF p_shipment_batch_id IS NULL THEN RAISE EXCEPTION 'Shipment batch id is required.'; END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN RAISE EXCEPTION 'Active shipper user account not found.'; END IF;

  SELECT b.shipper_id, b.status INTO v_batch_shipper_id, v_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch_shipper_id IS NULL THEN RAISE EXCEPTION 'Shipment batch not found.'; END IF;
  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN RAISE EXCEPTION 'Shipment batch does not belong to this shipper.'; END IF;
  IF v_status IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Export evidence fields cannot be edited for shipment batch status: %', v_status; END IF;

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
    shipment_batch_id, shipper_id, mbl_bol_sea_waybill_ref, container_number,
    seal_number, vessel_voyage, port_of_loading, port_of_discharge, place_of_delivery,
    export_shipment_date, final_package_confirmation, authorised_name,
    signature_stamp_confirmation_yn, notes, completion_status,
    created_by_shipper_user_id, updated_by_shipper_user_id
  ) VALUES (
    p_shipment_batch_id, v_shipper_id,
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
    v_completion_status, v_shipper_user_id, v_shipper_user_id
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

REVOKE ALL ON FUNCTION public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text) TO authenticated;

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
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: submit shipping document requires auth.uid()'; END IF;
  IF p_document_kind NOT IN ('shipper_invoice','shipper_receipt','supporting_charge_document') THEN RAISE EXCEPTION 'Choose a valid shipping document type.'; END IF;
  IF NULLIF(BTRIM(COALESCE(p_file_url, '')), '') IS NULL THEN RAISE EXCEPTION 'Shipping document file is required.'; END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL THEN RAISE EXCEPTION 'Active shipper user account not found.'; END IF;

  SELECT b.importer_id INTO v_importer_id
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
    AND b.shipper_id = v_shipper_id
    AND b.status <> 'voided'
  FOR UPDATE;

  IF v_importer_id IS NULL THEN RAISE EXCEPTION 'Shipment batch not found for this shipper, or batch is voided.'; END IF;

  SELECT * INTO v_existing
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id AND sd.active = true
  ORDER BY sd.created_at DESC LIMIT 1;

  IF v_existing.id IS NOT NULL AND v_existing.review_status = 'accepted_current' THEN
    RAISE EXCEPTION 'Supervisor has accepted the current shipping charge document for this batch. Request resubmission instead of replacing it.';
  END IF;

  SELECT COALESCE(MAX(sd.version_no), 0) + 1 INTO v_next_version
  FROM public.shipping_documents sd
  WHERE sd.shipment_batch_id = p_shipment_batch_id;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.shipping_documents
    SET active = false, review_status = 'superseded', superseded_at = now(), updated_at = now()
    WHERE shipment_batch_id = p_shipment_batch_id AND active = true;
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
    UPDATE public.shipping_documents SET replaced_by_document_id = v_document_id, updated_at = now()
    WHERE id = v_existing.id;
  END IF;

  RETURN v_document_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text) TO authenticated;

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
SET search_path = public, pg_temp
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
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL THEN RAISE EXCEPTION 'Active shipper user account not found.'; END IF;

  SELECT b.shipper_id, b.status INTO v_batch_shipper_id, v_batch_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = p_shipment_batch_id
  FOR UPDATE;

  IF v_batch_shipper_id IS NULL THEN RAISE EXCEPTION 'Shipment batch not found.'; END IF;
  IF v_batch_shipper_id IS DISTINCT FROM v_shipper_id THEN RAISE EXCEPTION 'Shipment batch does not belong to this shipper.'; END IF;
  IF v_batch_status IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'Final export evidence cannot be submitted for shipment batch status: %', v_batch_status; END IF;

  SELECT f.completion_status INTO v_completion_status
  FROM public.shipper_export_evidence_completion_fields f
  WHERE f.shipment_batch_id = p_shipment_batch_id;

  IF COALESCE(v_completion_status,'completion_fields_draft') <> 'completion_fields_ready' THEN
    RAISE EXCEPTION 'Complete and save final shipment/COS fields before uploading final export evidence.';
  END IF;

  INSERT INTO public.shipper_final_export_evidence_documents (
    shipment_batch_id, shipper_id, document_kind, document_ref, file_url, notes,
    review_status, created_by_shipper_user_id
  ) VALUES (
    p_shipment_batch_id, v_shipper_id, p_document_kind,
    NULLIF(BTRIM(COALESCE(p_document_ref,'')),''),
    BTRIM(COALESCE(p_file_url,'')),
    NULLIF(BTRIM(COALESCE(p_notes,'')),''),
    'submitted_for_review', v_shipper_user_id
  ) RETURNING id INTO v_document_id;

  RETURN v_document_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_review_final_export_evidence_document_v1(
  p_document_id uuid,
  p_review_status text,
  p_review_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_shipment_batch_id uuid;
  v_batch_status text;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  ORDER BY s.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'Active supervisor/admin staff account required.'; END IF;

  SELECT d.shipment_batch_id INTO v_shipment_batch_id
  FROM public.shipper_final_export_evidence_documents d
  WHERE d.id = p_document_id;

  IF v_shipment_batch_id IS NULL THEN RAISE EXCEPTION 'Final export evidence document not found.'; END IF;

  SELECT b.status INTO v_batch_status
  FROM public.shipper_shipment_batches b
  WHERE b.id = v_shipment_batch_id
  FOR UPDATE;

  IF v_batch_status IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Final export evidence cannot be reviewed for shipment batch status: %', v_batch_status;
  END IF;

  UPDATE public.shipper_final_export_evidence_documents d
  SET review_status = p_review_status,
      supervisor_review_notes = NULLIF(BTRIM(COALESCE(p_review_notes,'')),''),
      reviewed_by_staff_id = v_staff_id,
      reviewed_at = now(),
      updated_at = now()
  WHERE d.id = p_document_id
  RETURNING d.shipment_batch_id INTO v_shipment_batch_id;

  RETURN v_shipment_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_review_final_export_evidence_document_v1(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_review_final_export_evidence_document_v1(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_create_groupage_movement_v1(
  p_shipment_batch_ids uuid[],
  p_groupage_movement_ref text,
  p_profile_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_movement_id uuid;
  v_selected_count integer;
  v_batch_count integer;
  v_distinct_shipper_count integer;
  v_voided_count integer;
  v_missing_booking_count integer;
  v_grouped_count integer;
  v_exporter_name text;
  v_exporter_address text;
  v_exporter_vat_number text;
  v_default_consignee_name text;
  v_default_consignee_address text;
  v_default_notify_party_name text;
  v_default_notify_party_address text;
  v_shipper_name text;
  v_distinct_country_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: create groupage movement requires auth.uid()'; END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid() AND su.active = true
  ORDER BY su.created_at DESC LIMIT 1;

  IF v_shipper_user_id IS NULL THEN RAISE EXCEPTION 'Active shipper user account not found.'; END IF;
  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN RAISE EXCEPTION 'Select at least one shipment batch.'; END IF;

  SELECT COUNT(DISTINCT x)::integer INTO v_selected_count FROM unnest(p_shipment_batch_ids) AS x;

  -- Deterministic lock before current validation prevents Groupage creation from
  -- racing a Shipment Batch Undo.
  PERFORM 1
  FROM public.shipper_shipment_batches b
  WHERE b.id = ANY(p_shipment_batch_ids)
  ORDER BY b.id
  FOR UPDATE;

  SELECT COUNT(DISTINCT b.id)::integer,
         COUNT(DISTINCT b.shipper_id)::integer,
         COUNT(*) FILTER (WHERE b.status = 'voided')::integer,
         COUNT(*) FILTER (WHERE NULLIF(BTRIM(COALESCE(b.booking_ref, '')), '') IS NULL)::integer,
         COUNT(*) FILTER (WHERE gmb.id IS NOT NULL)::integer
  INTO v_batch_count, v_distinct_shipper_count, v_voided_count, v_missing_booking_count, v_grouped_count
  FROM unnest(p_shipment_batch_ids) AS selected(batch_id)
  LEFT JOIN public.shipper_shipment_batches b ON b.id = selected.batch_id
  LEFT JOIN public.shipper_groupage_movement_batches gmb ON gmb.shipment_batch_id = b.id AND gmb.active = true;

  IF v_batch_count <> v_selected_count THEN RAISE EXCEPTION 'One or more selected shipment batches were not found.'; END IF;
  IF v_distinct_shipper_count <> 1 THEN RAISE EXCEPTION 'Selected shipment batches must belong to one shipper.'; END IF;
  IF EXISTS (SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id = ANY(p_shipment_batch_ids) AND b.shipper_id IS DISTINCT FROM v_shipper_id) THEN RAISE EXCEPTION 'Selected shipment batches do not belong to this shipper.'; END IF;
  IF v_voided_count > 0 THEN RAISE EXCEPTION 'Voided shipment batches cannot be grouped.'; END IF;
  IF v_missing_booking_count > 0 THEN RAISE EXCEPTION 'Every selected batch must have a real booking reference.'; END IF;
  IF v_grouped_count > 0 THEN RAISE EXCEPTION 'One or more selected batches are already in an active Groupage Movement.'; END IF;
  IF NULLIF(BTRIM(COALESCE(p_groupage_movement_ref, '')), '') IS NULL THEN RAISE EXCEPTION 'Groupage movement reference is required.'; END IF;

  SELECT COUNT(DISTINCT dp.country_id)::integer INTO v_distinct_country_count
  FROM public.shipper_shipment_batches b
  JOIN unnest(p_shipment_batch_ids) selected(batch_id) ON selected.batch_id = b.id
  LEFT JOIN LATERAL (
    SELECT dp0.country_id FROM public.importer_export_delivery_profiles dp0
    WHERE dp0.importer_id = b.importer_id AND dp0.active = true
    ORDER BY dp0.updated_at DESC, dp0.created_at DESC LIMIT 1
  ) dp ON true
  WHERE dp.country_id IS NOT NULL;

  IF COALESCE(v_distinct_country_count, 0) > 1 THEN RAISE EXCEPTION 'Selected shipment batches must belong to one destination jurisdiction.'; END IF;

  SELECT p.exporter_name, p.exporter_address, p.exporter_vat_number,
         p.default_movement_consignee_name, p.default_movement_consignee_address,
         p.default_notify_party_name, p.default_notify_party_address
  INTO v_exporter_name, v_exporter_address, v_exporter_vat_number,
       v_default_consignee_name, v_default_consignee_address,
       v_default_notify_party_name, v_default_notify_party_address
  FROM public.tenant_export_evidence_profiles p
  WHERE p.active = true
    AND (p_profile_id IS NULL OR p.id = p_profile_id)
    AND (p.shipper_id IS NULL OR p.shipper_id = v_shipper_id)
  ORDER BY CASE WHEN p.id = p_profile_id THEN 0 WHEN p.shipper_id = v_shipper_id THEN 1 ELSE 2 END,
           p.updated_at DESC, p.created_at DESC
  LIMIT 1;

  SELECT s.name::text INTO v_shipper_name FROM public.shippers s WHERE s.id = v_shipper_id;

  INSERT INTO public.shipper_groupage_movements (
    shipper_id, destination_country_id, groupage_movement_ref, status,
    exporter_name_snapshot, exporter_address_snapshot, exporter_vat_number_snapshot,
    shipper_name_snapshot, movement_consignee_name_snapshot, movement_consignee_address_snapshot,
    notify_party_name_snapshot, notify_party_address_snapshot,
    created_by_shipper_user_id, updated_by_shipper_user_id
  ) VALUES (
    v_shipper_id,
    (
      SELECT dp.country_id
      FROM public.shipper_shipment_batches b
      JOIN unnest(p_shipment_batch_ids) selected(batch_id) ON selected.batch_id = b.id
      LEFT JOIN LATERAL (
        SELECT dp0.country_id FROM public.importer_export_delivery_profiles dp0
        WHERE dp0.importer_id = b.importer_id AND dp0.active = true
        ORDER BY dp0.updated_at DESC, dp0.created_at DESC LIMIT 1
      ) dp ON true
      WHERE dp.country_id IS NOT NULL LIMIT 1
    ),
    BTRIM(p_groupage_movement_ref), 'draft',
    v_exporter_name, v_exporter_address, v_exporter_vat_number, v_shipper_name,
    v_default_consignee_name, v_default_consignee_address,
    v_default_notify_party_name, v_default_notify_party_address,
    v_shipper_user_id, v_shipper_user_id
  ) RETURNING id INTO v_movement_id;

  INSERT INTO public.shipper_groupage_movement_batches (
    groupage_movement_id, shipment_batch_id, shipper_id, importer_id_snapshot,
    importer_name_snapshot, booking_ref_snapshot,
    final_recipient_name_snapshot, final_recipient_address_snapshot
  )
  SELECT v_movement_id, b.id, b.shipper_id, b.importer_id,
         COALESCE(NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text,
         b.booking_ref::text,
         COALESCE(NULLIF(dp.final_recipient_name, ''), NULLIF(i.trading_name, ''), i.company_name, i.id::text)::text,
         NULLIF(CONCAT_WS(', ', dp.final_recipient_address_line_1, dp.final_recipient_address_line_2,
                                dp.final_recipient_city, dp.final_recipient_region, dp.final_recipient_country), '')::text
  FROM public.shipper_shipment_batches b
  LEFT JOIN public.importers i ON i.id = b.importer_id
  LEFT JOIN LATERAL (
    SELECT dp0.* FROM public.importer_export_delivery_profiles dp0
    WHERE dp0.importer_id = b.importer_id AND dp0.active = true
    ORDER BY dp0.updated_at DESC, dp0.created_at DESC LIMIT 1
  ) dp ON true
  WHERE b.id = ANY(p_shipment_batch_ids);

  RETURN v_movement_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_create_groupage_movement_v1(uuid[],text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_create_groupage_movement_v1(uuid[],text,uuid) TO authenticated;

-- Installation postflight: structural checks only. Runtime behavioural proof lives
-- in the governed regression file.
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
