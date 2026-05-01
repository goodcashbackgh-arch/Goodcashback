-- =============================================================================
-- seed_major_uk_retailers_v1.sql
-- Multi Tenant Platform Build — additive retailer seed/config patch
--
-- Purpose:
--   Add major UK retailers to the global retailers table and enable them for
--   active shippers through shipper_retailers so they appear in the create-order
--   retailer dropdown.
--
-- Important boundary:
--   This does NOT create retailer_accounts. Invoice upload later still requires
--   a deterministic retailer_account_id for the selected retailer/shipper/hub
--   context. Do not create fake retailer account credentials from this patch.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.retailers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.retailers';
  END IF;

  IF to_regclass('public.shippers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shippers';
  END IF;

  IF to_regclass('public.shipper_retailers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipper_retailers';
  END IF;
END $$;

WITH wanted(name, website_url) AS (
  VALUES
    ('Amazon UK', 'https://www.amazon.co.uk'),
    ('Argos', 'https://www.argos.co.uk'),
    ('Currys', 'https://www.currys.co.uk'),
    ('AO', 'https://ao.com'),
    ('Ninja Kitchen', 'https://ninjakitchen.co.uk'),
    ('John Lewis', 'https://www.johnlewis.com'),
    ('IKEA', 'https://www.ikea.com/gb/en'),
    ('Dunelm', 'https://www.dunelm.com'),
    ('Zara', 'https://www.zara.com/uk'),
    ('H&M', 'https://www2.hm.com/en_gb/index.html'),
    ('Next', 'https://www.next.co.uk'),
    ('Marks & Spencer', 'https://www.marksandspencer.com'),
    ('ASOS', 'https://www.asos.com'),
    ('Sports Direct', 'https://www.sportsdirect.com'),
    ('Very', 'https://www.very.co.uk')
), inserted AS (
  INSERT INTO public.retailers (name, website_url, global_enabled)
  SELECT
    w.name,
    w.website_url,
    true
  FROM wanted w
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.retailers r
    WHERE lower(regexp_replace(r.name, '[^a-z0-9]+', '', 'g'))
        = lower(regexp_replace(w.name, '[^a-z0-9]+', '', 'g'))
  )
  RETURNING id, name
), wanted_retailers AS (
  SELECT r.id, r.name
  FROM public.retailers r
  JOIN wanted w
    ON lower(regexp_replace(r.name, '[^a-z0-9]+', '', 'g'))
     = lower(regexp_replace(w.name, '[^a-z0-9]+', '', 'g'))
), linked AS (
  INSERT INTO public.shipper_retailers (shipper_id, retailer_id, enabled)
  SELECT
    s.id,
    wr.id,
    true
  FROM public.shippers s
  CROSS JOIN wanted_retailers wr
  WHERE COALESCE(s.active, true) = true
  ON CONFLICT (shipper_id, retailer_id)
  DO UPDATE SET enabled = true
  RETURNING shipper_id, retailer_id
)
SELECT
  (SELECT count(*) FROM wanted) AS requested_retailers,
  (SELECT count(*) FROM inserted) AS newly_inserted_retailers,
  (SELECT count(*) FROM linked) AS shipper_retailer_links_inserted_or_enabled;

COMMIT;
