BEGIN;

-- Allow the admin-only VAT Sage evidence page to read posting API log evidence.
-- This is read-only and does not expose writes or token data.

ALTER TABLE public.sage_api_request_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_api_response_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sage_api_request_log_admin_select_for_vat_evidence_v1
ON public.sage_api_request_log;

CREATE POLICY sage_api_request_log_admin_select_for_vat_evidence_v1
ON public.sage_api_request_log
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active IS TRUE
      AND s.role_type = 'admin'
  )
);

DROP POLICY IF EXISTS sage_api_response_log_admin_select_for_vat_evidence_v1
ON public.sage_api_response_log;

CREATE POLICY sage_api_response_log_admin_select_for_vat_evidence_v1
ON public.sage_api_response_log
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active IS TRUE
      AND s.role_type = 'admin'
  )
);

NOTIFY pgrst, 'reload schema';

COMMIT;
