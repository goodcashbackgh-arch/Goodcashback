BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Groupage Movement guard: only non-empty batches can be grouped.
-- A selectable batch must have at least one active package and positive export-pack quantity.

CREATE OR REPLACE FUNCTION public.shipper_groupage_batch_non_empty_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_package_count integer := 0;
  v_line_count integer := 0;
  v_qty numeric := 0;
BEGIN
  IF COALESCE(NEW.active, true) = false THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*)::integer INTO v_package_count
  FROM public.shipper_shipment_batch_packages p
  WHERE p.shipment_batch_id = NEW.shipment_batch_id
    AND p.active = true;

  SELECT COUNT(*)::integer, COALESCE(SUM(pr.qty_allocated), 0)::numeric
  INTO v_line_count, v_qty
  FROM public.shipper_export_evidence_pack_preview_v1(NEW.shipment_batch_id) pr;

  IF COALESCE(v_package_count, 0) <= 0 OR COALESCE(v_line_count, 0) <= 0 OR COALESCE(v_qty, 0) <= 0 THEN
    RAISE EXCEPTION 'This shipment batch has no active packages/export quantity and cannot be added to a Groupage Movement.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shipper_groupage_batch_non_empty_guard_v1
  ON public.shipper_groupage_movement_batches;

CREATE TRIGGER trg_shipper_groupage_batch_non_empty_guard_v1
BEFORE INSERT OR UPDATE OF shipment_batch_id, active
ON public.shipper_groupage_movement_batches
FOR EACH ROW
EXECUTE FUNCTION public.shipper_groupage_batch_non_empty_guard_v1();

NOTIFY pgrst, 'reload schema';

COMMIT;
