BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Groupage Movement guard.
-- Normal shipper-created Groupage Movements should not include batches that already have
-- submitted or accepted final export/POD evidence. That avoids duplicate evidence rows
-- and keeps the groupage movement as a pre-evidence control layer.
-- Rejected/resubmit evidence is intentionally not blocked here so a corrected groupage pack
-- can still be used where a previous evidence submission failed review.

CREATE OR REPLACE FUNCTION public.shipper_groupage_movement_batch_evidence_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF COALESCE(NEW.active, true) = true AND EXISTS (
    SELECT 1
    FROM public.shipper_final_export_evidence_documents d
    WHERE d.shipment_batch_id = NEW.shipment_batch_id
      AND d.review_status IN ('submitted_for_review', 'accepted_current')
  ) THEN
    RAISE EXCEPTION 'This shipment batch already has submitted or accepted final export/POD evidence and cannot be added to a new Groupage Movement.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shipper_groupage_movement_batch_evidence_guard_v1
  ON public.shipper_groupage_movement_batches;

CREATE TRIGGER trg_shipper_groupage_movement_batch_evidence_guard_v1
BEFORE INSERT OR UPDATE OF shipment_batch_id, active
ON public.shipper_groupage_movement_batches
FOR EACH ROW
EXECUTE FUNCTION public.shipper_groupage_movement_batch_evidence_guard_v1();

NOTIFY pgrst, 'reload schema';

COMMIT;
