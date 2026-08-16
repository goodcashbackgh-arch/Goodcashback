-- PATCH_C2_TEST_IMPORTER_SELECTION_PROBE_V1
-- READ ONLY.
-- Purpose: choose the safest existing importer/customer record for the disposable Patch C2 login.
-- This does NOT read, change, reset, or require any user's password.

WITH importer_rows AS (
  SELECT
    i.id AS importer_id,
    i.importer_name,
    i.company_name,
    i.shipper_id,
    i.country_id
  FROM public.importers i
),
order_counts AS (
  SELECT o.importer_id, count(*)::int AS order_count
  FROM public.orders o
  GROUP BY o.importer_id
),
operator_links AS (
  SELECT
    oi.importer_id,
    count(*) FILTER (WHERE oi.revoked_at IS NULL)::int AS active_operator_links,
    count(*)::int AS total_operator_links
  FROM public.operator_importers oi
  GROUP BY oi.importer_id
),
membership_counts AS (
  SELECT
    m.importer_id,
    count(*) FILTER (
      WHERE m.active = true
        AND m.revoked_at IS NULL
        AND m.role_code IN ('customer','importer')
    )::int AS active_portal_memberships
  FROM public.platform_user_memberships m
  WHERE m.importer_id IS NOT NULL
  GROUP BY m.importer_id
),
auth_links AS (
  SELECT
    oi.importer_id,
    count(DISTINCT o.auth_user_id) FILTER (
      WHERE oi.revoked_at IS NULL
        AND o.auth_user_id IS NOT NULL
    )::int AS linked_auth_users,
    count(DISTINCT o.auth_user_id) FILTER (
      WHERE oi.revoked_at IS NULL
        AND o.auth_user_id IS NOT NULL
        AND au.id IS NOT NULL
    )::int AS linked_auth_users_present,
    count(DISTINCT o.auth_user_id) FILTER (
      WHERE oi.revoked_at IS NULL
        AND au.last_sign_in_at IS NOT NULL
    )::int AS linked_auth_users_ever_signed_in
  FROM public.operator_importers oi
  JOIN public.operators o ON o.id = oi.operator_id
  LEFT JOIN auth.users au ON au.id = o.auth_user_id
  GROUP BY oi.importer_id
),
result_rows AS (
  SELECT
    i.importer_id,
    i.importer_name,
    i.company_name,
    i.shipper_id,
    i.country_id,
    COALESCE(oc.order_count, 0) AS order_count,
    COALESCE(ol.active_operator_links, 0) AS active_operator_links,
    COALESCE(ol.total_operator_links, 0) AS total_operator_links,
    COALESCE(mc.active_portal_memberships, 0) AS active_portal_memberships,
    COALESCE(al.linked_auth_users, 0) AS linked_auth_users,
    COALESCE(al.linked_auth_users_present, 0) AS linked_auth_users_present,
    COALESCE(al.linked_auth_users_ever_signed_in, 0) AS linked_auth_users_ever_signed_in
  FROM importer_rows i
  LEFT JOIN order_counts oc ON oc.importer_id = i.importer_id
  LEFT JOIN operator_links ol ON ol.importer_id = i.importer_id
  LEFT JOIN membership_counts mc ON mc.importer_id = i.importer_id
  LEFT JOIN auth_links al ON al.importer_id = i.importer_id
)
SELECT jsonb_build_object(
  'probe', 'PATCH_C2_TEST_IMPORTER_SELECTION_PROBE_V1',
  'read_only', true,
  'passwords_read_or_changed', false,
  'importers', COALESCE(
    (
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.order_count, r.active_operator_links, r.importer_name)
      FROM result_rows r
    ),
    '[]'::jsonb
  )
) AS result;
