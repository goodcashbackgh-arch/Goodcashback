BEGIN;

REVOKE EXECUTE ON FUNCTION public.shipper_upsert_export_evidence_profile_v1(uuid,text,text,text,text,text,text,text,text) FROM authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
