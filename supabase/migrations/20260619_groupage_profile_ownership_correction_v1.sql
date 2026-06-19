BEGIN;

-- Contract correction: importer/customer delivery profile source records are onboarding data.
-- Shippers must not be the primary editor for those source records.

REVOKE EXECUTE ON FUNCTION public.shipper_upsert_importer_export_delivery_profile_v1(uuid,text,text,text,text,text,text,text,text) FROM authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
