BEGIN;

ALTER TABLE public.cash_posting_batch_rows
  ADD COLUMN IF NOT EXISTS sage_allocation_status text NOT NULL DEFAULT 'not_allocated',
  ADD COLUMN IF NOT EXISTS sage_allocation_id text,
  ADD COLUMN IF NOT EXISTS sage_allocation_amount_gbp numeric(18,2),
  ADD COLUMN IF NOT EXISTS sage_allocation_target_object_id text,
  ADD COLUMN IF NOT EXISTS sage_allocation_target_snapshot_id uuid,
  ADD COLUMN IF NOT EXISTS sage_allocation_request_payload jsonb,
  ADD COLUMN IF NOT EXISTS sage_allocation_response_payload jsonb,
  ADD COLUMN IF NOT EXISTS sage_allocation_error_code text,
  ADD COLUMN IF NOT EXISTS sage_allocation_error_message text,
  ADD COLUMN IF NOT EXISTS sage_allocation_posted_at timestamptz,
  ADD COLUMN IF NOT EXISTS sage_allocation_attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sage_allocation_last_attempt_at timestamptz;

ALTER TABLE public.cash_posting_snapshots
  ADD COLUMN IF NOT EXISTS sage_allocation_status text NOT NULL DEFAULT 'not_allocated',
  ADD COLUMN IF NOT EXISTS sage_allocation_id text,
  ADD COLUMN IF NOT EXISTS sage_allocation_amount_gbp numeric(18,2),
  ADD COLUMN IF NOT EXISTS sage_allocation_target_object_id text,
  ADD COLUMN IF NOT EXISTS sage_allocation_target_snapshot_id uuid,
  ADD COLUMN IF NOT EXISTS sage_allocation_request_payload jsonb,
  ADD COLUMN IF NOT EXISTS sage_allocation_response_payload jsonb,
  ADD COLUMN IF NOT EXISTS sage_allocation_error_code text,
  ADD COLUMN IF NOT EXISTS sage_allocation_error_message text,
  ADD COLUMN IF NOT EXISTS sage_allocation_posted_at timestamptz,
  ADD COLUMN IF NOT EXISTS sage_allocation_attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sage_allocation_last_attempt_at timestamptz;

COMMIT;
