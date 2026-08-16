-- PATCH_G_FINAL_ACCEPTANCE_PREFLIGHT_V1
-- READ ONLY. No writes.
-- Governing authority: MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1 section 10 / Patch G.

WITH resolver AS (
  SELECT
    p.oid,
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'current_platform_access_context_v1'
),
active_profiles AS (
  SELECT
    p.auth_user_id,
    p.email,
    p.display_name,
    p.must_change_password,
    EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p.auth_user_id) AS auth_user_present
  FROM public.platform_user_profiles p
  WHERE p.active = true
),
active_roles AS (
  SELECT
    m.auth_user_id,
    array_agg(m.role_code ORDER BY m.role_code) AS roles,
    bool_or(m.role_code IN ('admin','supervisor')) AS has_internal,
    bool_or(m.role_code IN ('shipper_admin','shipper_operator','shipper_readonly')) AS has_shipper,
    bool_or(m.role_code = 'customer') AS has_customer,
    bool_or(m.role_code = 'importer') AS has_importer
  FROM public.platform_user_memberships m
  WHERE m.active = true
    AND m.revoked_at IS NULL
  GROUP BY m.auth_user_id
),
routing AS (
  SELECT
    p.auth_user_id,
    p.email,
    p.display_name,
    p.auth_user_present,
    p.must_change_password,
    COALESCE(r.roles, ARRAY[]::text[]) AS active_roles,
    CASE
      WHEN p.must_change_password THEN '/auth/change-password'
      WHEN COALESCE(r.has_internal, false) THEN '/internal'
      WHEN COALESCE(r.has_shipper, false) THEN '/shipper'
      WHEN COALESCE(r.has_customer, false) AND COALESCE(r.has_importer, false) THEN '/workspace/select'
      WHEN COALESCE(r.has_customer, false) THEN '/customer'
      WHEN COALESCE(r.has_importer, false) THEN '/importer'
      WHEN EXISTS (SELECT 1 FROM public.staff s WHERE s.auth_user_id=p.auth_user_id AND s.active=true) THEN '/internal'
      WHEN EXISTS (SELECT 1 FROM public.shipper_users su WHERE su.auth_user_id=p.auth_user_id AND su.active=true) THEN '/shipper'
      WHEN EXISTS (SELECT 1 FROM public.operators o WHERE o.auth_user_id=p.auth_user_id AND o.active=true) THEN '/importer'
      ELSE NULL
    END AS expected_path,
    CASE
      WHEN NOT p.auth_user_present THEN 'stale_or_test_auth_id'
      WHEN p.must_change_password THEN NULL
      WHEN COALESCE(r.has_internal,false) OR COALESCE(r.has_shipper,false) OR COALESCE(r.has_customer,false) OR COALESCE(r.has_importer,false) THEN NULL
      ELSE 'no_active_membership_using_legacy_fallback'
    END AS review_reason
  FROM active_profiles p
  LEFT JOIN active_roles r ON r.auth_user_id = p.auth_user_id
),
branch_country AS (
  SELECT
    sh.id AS shipper_id,
    sh.name AS shipper_name,
    count(DISTINCT sc.country_id) FILTER (WHERE c.active=true)::int AS active_country_count,
    array_agg(DISTINCT sc.country_id ORDER BY sc.country_id) FILTER (WHERE c.active=true) AS active_country_ids
  FROM public.shippers sh
  LEFT JOIN public.shipper_countries sc ON sc.shipper_id=sh.id
  LEFT JOIN public.countries c ON c.id=sc.country_id
  WHERE sh.active=true
  GROUP BY sh.id, sh.name
),
importer_alignment AS (
  SELECT
    i.id AS importer_id,
    i.company_name,
    i.shipper_id,
    i.country_id AS importer_country_id,
    bc.active_country_count,
    CASE
      WHEN bc.active_country_count = 1 THEN i.country_id = bc.active_country_ids[1]
      ELSE false
    END AS aligned
  FROM public.importers i
  JOIN branch_country bc ON bc.shipper_id=i.shipper_id
  WHERE i.active=true
),
retailer_pair_state AS (
  SELECT
    ra.shipper_id,
    ra.retailer_id,
    count(*) FILTER (WHERE ra.status='active')::int AS active_account_count
  FROM public.retailer_accounts ra
  WHERE ra.shipper_id IS NOT NULL
  GROUP BY ra.shipper_id, ra.retailer_id
),
operational_pairs AS (
  SELECT DISTINCT o.shipper_id, o.retailer_id
  FROM public.orders o
),
patch_c_target AS (
  SELECT u.id AS auth_user_id
  FROM auth.users u
  WHERE lower(u.email)='patch-c-test-20260816-2205@example.com'
  LIMIT 1
),
patch_c_state AS (
  SELECT jsonb_build_object(
    'auth_user_id', t.auth_user_id,
    'profile_active', COALESCE(p.active,false),
    'must_change_password', p.must_change_password,
    'active_roles', COALESCE((
      SELECT jsonb_agg(m.role_code ORDER BY m.role_code)
      FROM public.platform_user_memberships m
      WHERE m.auth_user_id=t.auth_user_id AND m.active=true AND m.revoked_at IS NULL
        AND m.role_code IN ('customer','importer')
    ), '[]'::jsonb),
    'onboarding_audit_present', EXISTS (
      SELECT 1 FROM public.platform_access_audit_log a
      WHERE a.target_auth_user_id=t.auth_user_id AND a.action_type='operator_onboarding_created'
    ),
    'password_change_audit_present', EXISTS (
      SELECT 1 FROM public.platform_access_audit_log a
      WHERE a.target_auth_user_id=t.auth_user_id AND a.action_type='required_password_change_completed'
    )
  ) AS value
  FROM patch_c_target t
  LEFT JOIN public.platform_user_profiles p ON p.auth_user_id=t.auth_user_id
),
continuity AS (
  SELECT jsonb_build_object(
    'orders', (SELECT count(*) FROM public.orders),
    'supplier_invoices', (SELECT count(*) FROM public.supplier_invoices),
    'funding_events', (SELECT count(*) FROM public.order_funding_events),
    'retailer_accounts', (SELECT count(*) FROM public.retailer_accounts),
    'importers', (SELECT count(*) FROM public.importers),
    'operators', (SELECT count(*) FROM public.operators)
  ) AS value
)
SELECT jsonb_build_object(
  'probe','PATCH_G_FINAL_ACCEPTANCE_PREFLIGHT_V1',
  'read_only',true,
  'ready_for_manual_acceptance',
    (SELECT count(*)=1 FROM resolver)
    AND COALESCE((SELECT security_definer FROM resolver LIMIT 1),false)
    AND COALESCE((SELECT authenticated_execute FROM resolver LIMIT 1),false)
    AND NOT COALESCE((SELECT anon_execute FROM resolver LIMIT 1),true)
    AND NOT EXISTS (
      SELECT 1 FROM routing
      WHERE auth_user_present=true AND review_reason IS NOT NULL
    )
    AND NOT EXISTS (
      SELECT 1 FROM retailer_pair_state WHERE active_account_count > 1
    ),
  'review_required',
    (SELECT count(*) FROM routing WHERE auth_user_present=true AND review_reason IS NOT NULL)
    + (SELECT count(*) FROM retailer_pair_state WHERE active_account_count > 1),
  'resolver', jsonb_build_object(
    'count',(SELECT count(*) FROM resolver),
    'security_definer',COALESCE((SELECT security_definer FROM resolver LIMIT 1),false),
    'search_path_locked',COALESCE((SELECT config ILIKE '%search_path=public, pg_temp%' FROM resolver LIMIT 1),false),
    'authenticated_execute',COALESCE((SELECT authenticated_execute FROM resolver LIMIT 1),false),
    'anon_execute_revoked',NOT COALESCE((SELECT anon_execute FROM resolver LIMIT 1),true)
  ),
  'routing_state',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.email NULLS LAST,r.display_name) FROM routing r),'[]'::jsonb),
  'auth_present_user_count',(SELECT count(*) FROM routing WHERE auth_user_present=true),
  'stale_or_test_auth_id_count',(SELECT count(*) FROM routing WHERE auth_user_present=false),
  'branch_country_state',COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.shipper_name) FROM branch_country b),'[]'::jsonb),
  'existing_importer_alignment',COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.company_name) FROM importer_alignment i),'[]'::jsonb),
  'duplicate_active_retailer_shipper_pairs',(SELECT count(*) FROM retailer_pair_state WHERE active_account_count>1),
  'operational_pairs_total',(SELECT count(*) FROM operational_pairs),
  'operational_pairs_with_exactly_one_active_account',(
    SELECT count(*) FROM operational_pairs op
    LEFT JOIN retailer_pair_state r ON r.shipper_id=op.shipper_id AND r.retailer_id=op.retailer_id
    WHERE COALESCE(r.active_account_count,0)=1
  ),
  'operational_pairs_missing_active_account',(
    SELECT count(*) FROM operational_pairs op
    LEFT JOIN retailer_pair_state r ON r.shipper_id=op.shipper_id AND r.retailer_id=op.retailer_id
    WHERE COALESCE(r.active_account_count,0)=0
  ),
  'patch_c_disposable_user',COALESCE((SELECT value FROM patch_c_state),'{}'::jsonb),
  'continuity_counts',(SELECT value FROM continuity),
  'manual_acceptance_still_required',jsonb_build_array(
    'admin login -> /internal',
    'shipper login -> /shipper',
    'importer-only login -> /importer and customer denied',
    'dual-role login -> /workspace/select and both portals allowed',
    'disposable user Both -> Customer: importer denied',
    'disposable user Both -> Importer: customer denied',
    'restore disposable user to Customer + Importer',
    'smoke existing order/payment/shipment/evidence/accounting flows'
  ),
  'historical_rows_modified_by_probe',false
) AS result;
