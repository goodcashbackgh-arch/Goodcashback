BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS retailer_accounts_one_active_shipper_retailer_uidx
  ON public.retailer_accounts (shipper_id, retailer_id)
  WHERE shipper_id IS NOT NULL
    AND status = 'active';

CREATE OR REPLACE FUNCTION public.internal_retailer_account_readiness_v1()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid() AND s.active = true
  LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;

  RETURN jsonb_build_object(
    'retailers', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb)
      FROM (SELECT r.id, r.name, r.website_url, r.global_enabled FROM public.retailers r WHERE r.global_enabled = true) x
    ),
    'lanes', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.shipper_name, x.retailer_name), '[]'::jsonb)
      FROM (
        SELECT sr.shipper_id, sh.name AS shipper_name, sr.retailer_id, r.name AS retailer_name, sr.enabled,
          count(ra.id) FILTER (WHERE ra.status='active')::int AS active_account_count,
          (array_agg(ra.id ORDER BY ra.id) FILTER (WHERE ra.status='active'))[1] AS active_account_id,
          CASE WHEN count(ra.id) FILTER (WHERE ra.status='active')=1 THEN 'ready'
               WHEN count(ra.id) FILTER (WHERE ra.status='active')=0 THEN 'not_ready_missing_account'
               ELSE 'not_ready_ambiguous_accounts' END AS readiness
        FROM public.shipper_retailers sr
        JOIN public.shippers sh ON sh.id=sr.shipper_id AND sh.active=true
        JOIN public.retailers r ON r.id=sr.retailer_id AND r.global_enabled=true
        LEFT JOIN public.retailer_accounts ra ON ra.shipper_id=sr.shipper_id AND ra.retailer_id=sr.retailer_id
        WHERE sr.enabled=true
        GROUP BY sr.shipper_id, sh.name, sr.retailer_id, r.name, sr.enabled
      ) x
    ),
    'accounts', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.shipper_name, x.retailer_name, x.created_at, x.id), '[]'::jsonb)
      FROM (
        SELECT ra.id, ra.retailer_id, r.name AS retailer_name, ra.shipper_id, sh.name AS shipper_name,
          ra.account_email, ra.account_username, ra.credentials_vault_ref, ra.credential_delivery_method,
          ra.delivery_address_locked_to_hub_id, h.name AS delivery_hub_name, ra.card_last_4, ra.card_vault_ref,
          ra.status, ra.created_at
        FROM public.retailer_accounts ra
        JOIN public.retailers r ON r.id=ra.retailer_id
        LEFT JOIN public.shippers sh ON sh.id=ra.shipper_id
        LEFT JOIN public.hubs h ON h.id=ra.delivery_address_locked_to_hub_id
        WHERE ra.shipper_id IS NOT NULL
      ) x
    ),
    'hubs', (
      SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.shipper_name, x.name), '[]'::jsonb)
      FROM (
        SELECT h.id, h.shipper_id, sh.name AS shipper_name, h.name, h.country_id, h.full_address, h.postcode
        FROM public.hubs h
        JOIN public.shippers sh ON sh.id=h.shipper_id AND sh.active=true
        WHERE h.active=true AND h.shipper_id IS NOT NULL
      ) x
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.internal_retailer_account_readiness_v1() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.internal_retailer_account_readiness_v1() FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_retailer_account_readiness_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_upsert_retailer_account_v1(
  p_retailer_account_id uuid,
  p_shipper_id uuid,
  p_retailer_id uuid,
  p_account_email text,
  p_account_username text,
  p_credentials_vault_ref text,
  p_credential_delivery_method text,
  p_delivery_address_locked_to_hub_id uuid,
  p_card_last_4 text,
  p_card_vault_ref text,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_account_id uuid;
  v_existing record;
  v_email text := lower(btrim(COALESCE(p_account_email,'')));
  v_username text := NULLIF(btrim(COALESCE(p_account_username,'')),'');
  v_credentials_vault_ref text := NULLIF(btrim(COALESCE(p_credentials_vault_ref,'')),'');
  v_delivery_method text := btrim(COALESCE(p_credential_delivery_method,''));
  v_card_last_4 text := NULLIF(btrim(COALESCE(p_card_last_4,'')),'');
  v_card_vault_ref text := NULLIF(btrim(COALESCE(p_card_vault_ref,'')),'');
  v_status text := btrim(COALESCE(p_status,''));
BEGIN
  SELECT s.id INTO v_staff_id FROM public.staff s
  WHERE s.auth_user_id=auth.uid() AND s.active=true LIMIT 1;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'not_authorised'; END IF;
  IF p_shipper_id IS NULL THEN RAISE EXCEPTION 'shipper_required'; END IF;
  IF p_retailer_id IS NULL THEN RAISE EXCEPTION 'retailer_required'; END IF;
  IF v_email='' OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN RAISE EXCEPTION 'valid_account_email_required'; END IF;
  IF v_delivery_method NOT IN ('vault_brokered','shared_direct','pending_vault_upgrade') THEN RAISE EXCEPTION 'invalid_credential_delivery_method'; END IF;
  IF v_status NOT IN ('active','suspended','locked_out') THEN RAISE EXCEPTION 'invalid_retailer_account_status'; END IF;
  IF v_card_last_4 IS NOT NULL AND v_card_last_4 !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'card_last_4_must_be_four_digits'; END IF;

  PERFORM 1 FROM public.shippers sh WHERE sh.id=p_shipper_id AND sh.active=true FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'shipper_not_found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.retailers r WHERE r.id=p_retailer_id AND r.global_enabled=true) THEN RAISE EXCEPTION 'retailer_not_found_or_disabled'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.shipper_retailers sr WHERE sr.shipper_id=p_shipper_id AND sr.retailer_id=p_retailer_id AND sr.enabled=true) THEN RAISE EXCEPTION 'shipper_retailer_lane_not_enabled'; END IF;
  IF p_delivery_address_locked_to_hub_id IS NULL THEN RAISE EXCEPTION 'delivery_hub_required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.hubs h WHERE h.id=p_delivery_address_locked_to_hub_id AND h.shipper_id=p_shipper_id AND h.active=true) THEN RAISE EXCEPTION 'delivery_hub_not_active_for_shipper'; END IF;

  IF p_retailer_account_id IS NOT NULL THEN
    SELECT ra.* INTO v_existing FROM public.retailer_accounts ra WHERE ra.id=p_retailer_account_id FOR UPDATE;
    IF v_existing.id IS NULL THEN RAISE EXCEPTION 'retailer_account_not_found'; END IF;
    IF v_existing.shipper_id IS NULL THEN RAISE EXCEPTION 'shared_retailer_account_not_editable_in_shipper_lane'; END IF;
    IF v_existing.shipper_id IS DISTINCT FROM p_shipper_id OR v_existing.retailer_id IS DISTINCT FROM p_retailer_id THEN RAISE EXCEPTION 'retailer_account_lane_change_not_allowed'; END IF;
  END IF;

  IF v_status='active' AND EXISTS (
    SELECT 1 FROM public.retailer_accounts ra
    WHERE ra.shipper_id=p_shipper_id AND ra.retailer_id=p_retailer_id AND ra.status='active'
      AND (p_retailer_account_id IS NULL OR ra.id<>p_retailer_account_id)
  ) THEN RAISE EXCEPTION 'active_retailer_account_already_exists_for_lane'; END IF;

  IF p_retailer_account_id IS NULL THEN
    INSERT INTO public.retailer_accounts(retailer_id,shipper_id,account_email,account_username,credentials_vault_ref,credential_delivery_method,delivery_address_locked_to_hub_id,card_last_4,card_vault_ref,status)
    VALUES(p_retailer_id,p_shipper_id,v_email,v_username,v_credentials_vault_ref,v_delivery_method,p_delivery_address_locked_to_hub_id,v_card_last_4,v_card_vault_ref,v_status)
    RETURNING id INTO v_account_id;
  ELSE
    UPDATE public.retailer_accounts SET account_email=v_email, account_username=v_username, credentials_vault_ref=v_credentials_vault_ref,
      credential_delivery_method=v_delivery_method, delivery_address_locked_to_hub_id=p_delivery_address_locked_to_hub_id,
      card_last_4=v_card_last_4, card_vault_ref=v_card_vault_ref, status=v_status
    WHERE id=p_retailer_account_id RETURNING id INTO v_account_id;
  END IF;

  RETURN jsonb_build_object('ok',true,'retailer_account_id',v_account_id,'shipper_id',p_shipper_id,'retailer_id',p_retailer_id,'status',v_status,'ready',v_status='active');
END;
$$;

REVOKE ALL ON FUNCTION public.internal_upsert_retailer_account_v1(uuid,uuid,uuid,text,text,text,text,uuid,text,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.internal_upsert_retailer_account_v1(uuid,uuid,uuid,text,text,text,text,uuid,text,text,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_upsert_retailer_account_v1(uuid,uuid,uuid,text,text,text,text,uuid,text,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
