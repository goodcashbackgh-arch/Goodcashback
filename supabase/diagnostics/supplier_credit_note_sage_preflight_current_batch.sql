-- READ ONLY diagnostic for the current supplier credit note batch failure.
-- Replace the batch id if needed.
-- Shows what Sage purchase credit note needs vs what the frozen draft currently has,
-- including whether contact, ledger and tax ids exist in the latest saved Sage catalog cache.

WITH params AS (
  SELECT 'a0db3a4e-4a2a-46c8-b5d7-18e0447c8a1c'::uuid AS batch_id
), rows AS (
  SELECT r.*
  FROM public.sage_posting_batch_rows r
  JOIN params p ON p.batch_id = r.batch_id
  WHERE r.document_lane = 'supplier_credit_note'
), line_items AS (
  SELECT
    r.id AS row_id,
    r.batch_id,
    r.posting_status,
    r.payload_validation_status,
    r.error_message,
    r.request_payload_json #>> '{supplier_target,sage_contact_id}' AS contact_id,
    r.request_payload_json #>> '{sage_header,date}' AS document_date,
    r.request_payload_json #>> '{sage_header,reference}' AS reference,
    r.request_payload_json #>> '{controls,supplier_approval_status}' AS supplier_approval_status,
    r.request_payload_json #>> '{controls,supplier_control_status}' AS supplier_control_status,
    r.request_payload_json #>> '{controls,gross_reconciled_to_document_yn}' AS gross_reconciled_to_document_yn,
    r.request_payload_json #>> '{controls,all_progressed_lines_coded_yn}' AS all_progressed_lines_coded_yn,
    r.request_payload_json #>> '{controls,refund_in_allocation_covers_approved_amount}' AS refund_in_allocation_covers_approved_amount,
    line.value #>> '{description}' AS line_description,
    line.value #>> '{sage_ledger_account_id}' AS ledger_account_id,
    COALESCE(line.value #>> '{sage_tax_rate_id}', line.value #>> '{tax_rate_id}', line.value #>> '{resolved_tax_rate_id}') AS tax_rate_id,
    line.value #>> '{quantity}' AS quantity,
    COALESCE(line.value #>> '{net_credit_gbp}', line.value #>> '{net_amount_gbp}') AS net_amount_gbp,
    COALESCE(line.value #>> '{vat_credit_gbp}', line.value #>> '{vat_amount_gbp}') AS vat_amount_gbp,
    COALESCE(line.value #>> '{gross_credit_gbp}', line.value #>> '{gross_amount_gbp}', line.value #>> '{total_line_amount_gbp}', line.value #>> '{amount_gbp}') AS gross_amount_gbp
  FROM rows r
  LEFT JOIN LATERAL jsonb_array_elements(COALESCE(r.request_payload_json->'resolved_lines', '[]'::jsonb)) line(value) ON true
), latest_category AS (
  SELECT DISTINCT ON (category_key)
    sage_connection_id,
    sage_business_row_id,
    category_key,
    last_seen_at
  FROM public.sage_catalog_category_cache
  WHERE category_key IN ('contacts','ledger_accounts','tax_rates')
    AND ok = true
  ORDER BY category_key, last_seen_at DESC
)
SELECT
  li.batch_id,
  li.row_id,
  li.posting_status,
  li.payload_validation_status,
  li.error_message,
  CASE WHEN NULLIF(li.contact_id, '') IS NOT NULL THEN 'present' ELSE 'missing' END AS sage_contact_required_status,
  li.contact_id,
  CASE WHEN contact.sage_external_id IS NOT NULL THEN 'exists_in_saved_sage_contacts' ELSE 'not_found_in_saved_sage_contacts_or_catalog_stale' END AS contact_catalog_status,
  CASE WHEN NULLIF(li.document_date, '') IS NOT NULL THEN 'present' ELSE 'missing' END AS document_date_required_status,
  li.document_date,
  CASE WHEN NULLIF(li.reference, '') IS NOT NULL THEN 'present' ELSE 'missing' END AS reference_required_status,
  li.reference,
  li.supplier_approval_status,
  li.supplier_control_status,
  li.gross_reconciled_to_document_yn,
  li.all_progressed_lines_coded_yn,
  li.refund_in_allocation_covers_approved_amount,
  CASE WHEN NULLIF(li.line_description, '') IS NOT NULL THEN 'present' ELSE 'missing' END AS line_description_status,
  li.line_description,
  CASE WHEN NULLIF(li.ledger_account_id, '') IS NOT NULL THEN 'present' ELSE 'missing' END AS ledger_required_status,
  li.ledger_account_id,
  ledger.display_name AS ledger_catalog_name,
  CASE WHEN ledger.sage_external_id IS NOT NULL THEN 'exists_in_saved_sage_ledger_accounts' ELSE 'not_found_in_saved_sage_ledger_accounts_or_catalog_stale' END AS ledger_catalog_status,
  CASE WHEN NULLIF(li.tax_rate_id, '') IS NOT NULL THEN 'present' ELSE 'missing' END AS tax_required_status,
  li.tax_rate_id,
  tax.display_name AS tax_catalog_name,
  tax.reference_text AS tax_catalog_reference,
  tax.code_text AS tax_catalog_code,
  tax.sage_type AS tax_catalog_type,
  CASE WHEN tax.sage_external_id IS NOT NULL THEN 'exists_in_saved_sage_tax_rates' ELSE 'not_found_in_saved_sage_tax_rates_or_catalog_stale' END AS tax_catalog_status,
  li.quantity,
  li.net_amount_gbp,
  li.vat_amount_gbp,
  li.gross_amount_gbp
FROM line_items li
LEFT JOIN latest_category contact_cat ON contact_cat.category_key = 'contacts'
LEFT JOIN public.sage_catalog_cache contact
  ON contact.category_key = 'contacts'
 AND contact.sage_connection_id = contact_cat.sage_connection_id
 AND contact.sage_business_row_id IS NOT DISTINCT FROM contact_cat.sage_business_row_id
 AND contact.sage_external_id = li.contact_id
LEFT JOIN latest_category ledger_cat ON ledger_cat.category_key = 'ledger_accounts'
LEFT JOIN public.sage_catalog_cache ledger
  ON ledger.category_key = 'ledger_accounts'
 AND ledger.sage_connection_id = ledger_cat.sage_connection_id
 AND ledger.sage_business_row_id IS NOT DISTINCT FROM ledger_cat.sage_business_row_id
 AND ledger.sage_external_id = li.ledger_account_id
LEFT JOIN latest_category tax_cat ON tax_cat.category_key = 'tax_rates'
LEFT JOIN public.sage_catalog_cache tax
  ON tax.category_key = 'tax_rates'
 AND tax.sage_connection_id = tax_cat.sage_connection_id
 AND tax.sage_business_row_id IS NOT DISTINCT FROM tax_cat.sage_business_row_id
 AND tax.sage_external_id = li.tax_rate_id;
