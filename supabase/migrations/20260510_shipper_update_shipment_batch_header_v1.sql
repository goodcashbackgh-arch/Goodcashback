-- Shipment batch header correction only.
-- Scope: package/shipment truth. No COS, Sage, VAT, export lock, or package membership changes.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
  WHERE b.id = p_shipment_batch_id;

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
    container_ref = NULLIF(BTRIM(COALESCE(p_container_ref, '')), ''),
    bol_ref = NULLIF(BTRIM(COALESCE(p_bol_ref, '')), ''),
    notes = NULLIF(BTRIM(COALESCE(p_notes, '')), '')
  WHERE id = p_shipment_batch_id;

  RETURN p_shipment_batch_id;
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
