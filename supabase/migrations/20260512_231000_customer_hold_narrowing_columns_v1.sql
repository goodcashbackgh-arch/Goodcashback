BEGIN;

ALTER TABLE public.customer_pre_shipment_hold_requests
  ADD COLUMN IF NOT EXISTS narrowed_from_hold_request_id uuid REFERENCES public.customer_pre_shipment_hold_requests(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS superseded_by_hold_request_id uuid REFERENCES public.customer_pre_shipment_hold_requests(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_customer_hold_narrowed_from
  ON public.customer_pre_shipment_hold_requests(narrowed_from_hold_request_id)
  WHERE narrowed_from_hold_request_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_customer_hold_superseded_by
  ON public.customer_pre_shipment_hold_requests(superseded_by_hold_request_id)
  WHERE superseded_by_hold_request_id IS NOT NULL;

COMMIT;
