BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.shipper_exclude_groupage_batches_v1(
  p_groupage_movement_id uuid,
  p_shipment_batch_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_updated integer := 0;
  v_remaining integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: exclude groupage batches requires auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one booking reference to exclude.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movements gm
    WHERE gm.id = p_groupage_movement_id
      AND gm.shipper_id = v_shipper_id
      AND gm.status IN ('draft', 'movement_facts_incomplete', 'movement_facts_ready')
  ) THEN
    RAISE EXCEPTION 'Groupage Movement not found, not owned by this shipper, or no longer editable.';
  END IF;

  UPDATE public.shipper_groupage_movement_batches gmb
  SET active = false
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.shipper_id = v_shipper_id
    AND gmb.active = true
    AND gmb.shipment_batch_id = ANY(p_shipment_batch_ids);

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    RAISE EXCEPTION 'No active included booking references were excluded.';
  END IF;

  SELECT COUNT(*)::integer INTO v_remaining
  FROM public.shipper_groupage_movement_batches gmb
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.active = true;

  IF v_remaining < 2 THEN
    UPDATE public.shipper_groupage_movement_batches gmb
    SET active = false
    WHERE gmb.groupage_movement_id = p_groupage_movement_id
      AND gmb.shipper_id = v_shipper_id
      AND gmb.active = true;

    UPDATE public.shipper_groupage_movements gm
    SET status = 'voided', updated_by_shipper_user_id = v_shipper_user_id, updated_at = now()
    WHERE gm.id = p_groupage_movement_id;
  ELSE
    UPDATE public.shipper_groupage_movements gm
    SET updated_by_shipper_user_id = v_shipper_user_id, updated_at = now()
    WHERE gm.id = p_groupage_movement_id;
  END IF;

  RETURN v_updated;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_exclude_groupage_batches_v1(uuid, uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.shipper_cancel_groupage_movement_v1(p_groupage_movement_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: cancel groupage movement requires auth.uid()';
  END IF;

  SELECT su.id, su.shipper_id INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movements gm
    WHERE gm.id = p_groupage_movement_id
      AND gm.shipper_id = v_shipper_id
      AND gm.status IN ('draft', 'movement_facts_incomplete', 'movement_facts_ready')
  ) THEN
    RAISE EXCEPTION 'Groupage Movement not found, not owned by this shipper, or no longer cancellable.';
  END IF;

  UPDATE public.shipper_groupage_movement_batches gmb
  SET active = false
  WHERE gmb.groupage_movement_id = p_groupage_movement_id
    AND gmb.shipper_id = v_shipper_id
    AND gmb.active = true;

  UPDATE public.shipper_groupage_movements gm
  SET status = 'voided', updated_by_shipper_user_id = v_shipper_user_id, updated_at = now()
  WHERE gm.id = p_groupage_movement_id;

  RETURN p_groupage_movement_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.shipper_cancel_groupage_movement_v1(uuid) TO authenticated;

UPDATE public.shipper_groupage_movement_batches gmb
SET active = false
WHERE gmb.active = true
  AND EXISTS (
    SELECT 1
    FROM public.shipper_groupage_movements gm
    WHERE gm.id = gmb.groupage_movement_id
      AND gm.status <> 'voided'
      AND (
        SELECT COUNT(*)
        FROM public.shipper_groupage_movement_batches gmb2
        WHERE gmb2.groupage_movement_id = gm.id
          AND gmb2.active = true
      ) < 2
  );

UPDATE public.shipper_groupage_movements gm
SET status = 'voided', updated_at = now()
WHERE gm.status <> 'voided'
  AND (
    SELECT COUNT(*)
    FROM public.shipper_groupage_movement_batches gmb
    WHERE gmb.groupage_movement_id = gm.id
      AND gmb.active = true
  ) < 2;

NOTIFY pgrst, 'reload schema';

COMMIT;
