BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- VAT return reconstruction mappings only.
-- These rows create/select Sage Mapping cards for VAT Box coverage checks.
-- They do not post journals, submit VAT returns, pay VAT, or call HMRC.

WITH seed(mapping_code, display_name, description, required_for, sage_external_id, sage_display_name) AS (
  VALUES
    ('VAT_BOX1_OUTPUT_VAT_LEDGER', 'VAT Box 1 output VAT ledger', 'Sage VAT control ledger used to reconcile output VAT for Box 1. Standard Sage nominal: VAT on Sales (2200).', ARRAY['vat_return_reconstruction','vat_box_1']::text[], 'ea211d2c3be211f194130283b27a38ab', 'VAT on Sales (2200)'),
    ('VAT_BOX1_OUTPUT_VAT_HOLDING_REVIEW_LEDGER', 'VAT Box 1 output VAT holding review ledger', 'Sage holding ledger to review before Box 1 is treated as final. Standard Sage nominal: VAT on Sales - Holding Account (2204).', ARRAY['vat_return_reconstruction','vat_box_1','review_only']::text[], 'ea22717f3be211f194130283b27a38ab', 'VAT on Sales - Holding Account (2204)'),
    ('VAT_BOX4_INPUT_VAT_LEDGER', 'VAT Box 4 input VAT ledger', 'Sage VAT control ledger used to reconcile input VAT for Box 4. Standard Sage nominal: VAT on Purchases (2201).', ARRAY['vat_return_reconstruction','vat_box_4']::text[], 'ea2173253be211f194130283b27a38ab', 'VAT on Purchases (2201)'),
    ('VAT_BOX4_INPUT_VAT_HOLDING_REVIEW_LEDGER', 'VAT Box 4 input VAT holding review ledger', 'Sage holding ledger to review before Box 4 is treated as final. Standard Sage nominal: VAT on Purchases - Holding Account (2205).', ARRAY['vat_return_reconstruction','vat_box_4','review_only']::text[], 'ea22bec83be211f194130283b27a38ab', 'VAT on Purchases - Holding Account (2205)'),

    ('VAT_BOX6_SALES_PRODUCTS_LEDGER', 'VAT Box 6 sales products ledger', 'Sage income ledger used to reconcile VAT Box 6 net sales. Standard Sage nominal: Sales - Products (4000).', ARRAY['vat_return_reconstruction','vat_box_6']::text[], 'ea264e0b3be211f194130283b27a38ab', 'Sales - Products (4000)'),
    ('VAT_BOX6_SALES_SERVICES_LEDGER', 'VAT Box 6 sales services ledger', 'Sage income ledger used to reconcile VAT Box 6 net sales. Standard Sage nominal: Sales - Services (4010).', ARRAY['vat_return_reconstruction','vat_box_6']::text[], 'ea3190fc3be211f194130283b27a38ab', 'Sales - Services (4010)'),
    ('VAT_BOX6_SALES_DISCOUNTS_LEDGER', 'VAT Box 6 sales discounts ledger', 'Sage income contra ledger used to reconcile VAT Box 6 reductions. Standard Sage nominal: Sales Discounts (4020).', ARRAY['vat_return_reconstruction','vat_box_6','contra_income']::text[], 'ea26a2693be211f194130283b27a38ab', 'Sales Discounts (4020)'),
    ('VAT_BOX6_SALE_OF_ASSETS_LEDGER', 'VAT Box 6 sale of assets ledger', 'Sage income ledger to review for Box 6 where asset disposals are VAT-reportable. Standard Sage nominal: Sale of Assets (4200).', ARRAY['vat_return_reconstruction','vat_box_6','review_only']::text[], 'ea26efdc3be211f194130283b27a38ab', 'Sale of Assets (4200)'),
    ('VAT_BOX6_CARRIAGE_ON_SALES_LEDGER', 'VAT Box 6 carriage on sales ledger', 'Sage income ledger used to reconcile VAT Box 6 delivery/carriage charged to customers. Standard Sage nominal: Carriage on Sales (4910).', ARRAY['vat_return_reconstruction','vat_box_6']::text[], 'ea2828a73be211f194130283b27a38ab', 'Carriage on Sales (4910)'),

    ('VAT_BOX7_COST_OF_SALES_GOODS_LEDGER', 'VAT Box 7 cost of sales goods ledger', 'Sage cost ledger used to reconcile VAT Box 7 net purchases. Standard Sage nominal: Cost of Sales - Goods (5000).', ARRAY['vat_return_reconstruction','vat_box_7']::text[], 'ea287d593be211f194130283b27a38ab', 'Cost of Sales - Goods (5000)'),
    ('VAT_BOX7_COST_OF_SALES_MATERIALS_LEDGER', 'VAT Box 7 cost of sales materials ledger', 'Sage cost ledger used to reconcile VAT Box 7 net purchases. Standard Sage nominal: Cost of Sales - Materials (5020).', ARRAY['vat_return_reconstruction','vat_box_7']::text[], 'ea291553be211f194130283b27a38ab', 'Cost of Sales - Materials (5020)'),
    ('VAT_BOX7_COST_OF_SALES_DELIVERY_LEDGER', 'VAT Box 7 cost of sales delivery ledger', 'Sage delivery cost ledger used to reconcile VAT Box 7 net purchases. Standard Sage nominal: Cost of Sales - Delivery (5030).', ARRAY['vat_return_reconstruction','vat_box_7']::text[], 'ea296782be211f194130283b27a38ab', 'Cost of Sales - Delivery (5030)'),
    ('VAT_BOX7_COST_OF_SALES_LABOUR_LEDGER', 'VAT Box 7 cost of sales labour ledger', 'Sage labour/subcontract cost ledger used to reconcile VAT Box 7 where VAT-reportable. Standard Sage nominal: Cost of Sales - Labour (5040).', ARRAY['vat_return_reconstruction','vat_box_7','review_only']::text[], 'ea35b6b33be211f194130283b27a38ab', 'Cost of Sales - Labour (5040)'),
    ('VAT_BOX7_SUB_CONTRACTORS_LEDGER', 'VAT Box 7 sub-contractors ledger', 'Sage subcontractor cost ledger used to reconcile VAT Box 7 where VAT-reportable. Standard Sage nominal: Sub-Contractors (5050).', ARRAY['vat_return_reconstruction','vat_box_7','review_only']::text[], 'ea3610253be211f194130283b27a38ab', 'Sub-Contractors (5050)'),
    ('VAT_BOX7_CARRIAGE_ON_PURCHASES_LEDGER', 'VAT Box 7 carriage on purchases ledger', 'Sage purchase carriage ledger used to reconcile VAT Box 7. Standard Sage nominal: Carriage on Purchases (5100).', ARRAY['vat_return_reconstruction','vat_box_7']::text[], 'ea29af733be211f194130283b27a38ab', 'Carriage on Purchases (5100)'),
    ('VAT_BOX7_BANK_CHARGES_LEDGER', 'VAT Box 7 bank charges ledger', 'Sage expense ledger used to review bank charges for VAT Box 7 treatment. Standard Sage nominal: Bank Charges (7900).', ARRAY['vat_return_reconstruction','vat_box_7','review_only']::text[], 'ea2f74533be211f194130283b27a38ab', 'Bank Charges (7900)'),
    ('VAT_BOX7_BUSINESS_INSURANCE_LEDGER', 'VAT Box 7 business insurance ledger', 'Sage expense ledger used to review insurance for VAT Box 7 treatment. Standard Sage nominal: Business Insurance (7630).', ARRAY['vat_return_reconstruction','vat_box_7','review_only']::text[], 'ea2ece6d3be211f194130283b27a38ab', 'Business Insurance (7630)'),
    ('VAT_BOX7_TRAVELLING_LEDGER', 'VAT Box 7 travelling ledger', 'Sage expense ledger used to review travel costs for VAT Box 7 treatment. Standard Sage nominal: Travelling (7400).', ARRAY['vat_return_reconstruction','vat_box_7','review_only']::text[], 'ea2dd6053be211f194130283b27a38ab', 'Travelling (7400)'),
    ('VAT_BOX7_VEHICLE_FUEL_LEDGER', 'VAT Box 7 vehicle fuel ledger', 'Sage expense ledger used to review vehicle fuel costs for VAT Box 7 treatment. Standard Sage nominal: Vehicle Fuel (7300).', ARRAY['vat_return_reconstruction','vat_box_7','review_only']::text[], 'ea2d7b013be211f194130283b27a38ab', 'Vehicle Fuel (7300)')
)
INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for,
  sage_external_id,
  sage_display_name,
  is_active,
  configured_at,
  notes
)
SELECT
  seed.mapping_code,
  'vat_return_reconstruction'::text,
  seed.display_name,
  seed.description,
  'ledger_account_id'::text,
  seed.required_for,
  seed.sage_external_id,
  seed.sage_display_name,
  true,
  now(),
  'Seeded from Sage ledger account catalogue screenshots for VAT return reconstruction. Confirm if Sage chart of accounts changes.'::text
FROM seed
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    sage_external_id = COALESCE(NULLIF(trim(public.sage_mapping_settings.sage_external_id), ''), EXCLUDED.sage_external_id),
    sage_display_name = COALESCE(NULLIF(trim(public.sage_mapping_settings.sage_display_name), ''), EXCLUDED.sage_display_name),
    is_active = true,
    configured_at = CASE
      WHEN NULLIF(trim(COALESCE(public.sage_mapping_settings.sage_external_id, '')), '') IS NULL THEN now()
      ELSE public.sage_mapping_settings.configured_at
    END,
    notes = COALESCE(NULLIF(trim(public.sage_mapping_settings.notes), ''), EXCLUDED.notes),
    updated_at = now();

NOTIFY pgrst, 'reload schema';

COMMIT;
