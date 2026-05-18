import "server-only";

import { supabaseAdmin } from "@/lib/supabase/admin";

export function catalogItemValue(item: { id: string; display: string; reference: string; type: string }) {
  return JSON.stringify({ id: item.id, display: item.display, reference: item.reference, type: item.type });
}

export function parseCatalogItemValue(value: FormDataEntryValue | null) {
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const parsed = JSON.parse(value) as Partial<{ id: string; display: string; reference: string; type: string }>;
    if (!parsed.id) return null;
    return { id: String(parsed.id), display: String(parsed.display ?? ""), reference: String(parsed.reference ?? ""), type: String(parsed.type ?? "") };
  } catch {
    return null;
  }
}

export async function writeSavedCatalogCategory(input: {
  staffId: string;
  connectionId: string;
  businessRowId: string | null;
  businessId: string | null;
  categoryKey: string;
  categoryLabel: string;
  endpointPath: string;
  httpStatus: number | null;
  ok: boolean;
  rowCount: number;
  lastError: string | null;
}) {
  await supabaseAdmin.from("sage_catalog_category_cache").upsert({
    sage_connection_id: input.connectionId,
    sage_business_row_id: input.businessRowId,
    sage_business_id: input.businessId,
    category_key: input.categoryKey,
    category_label: input.categoryLabel,
    endpoint_path: input.endpointPath,
    http_status: input.httpStatus,
    ok: input.ok,
    row_count: input.rowCount,
    last_error: input.lastError,
    last_seen_at: new Date().toISOString(),
    last_seen_by_staff_id: input.staffId,
    updated_at: new Date().toISOString(),
  }, { onConflict: "sage_connection_id,sage_business_row_id,category_key" });
}

export async function writeSavedCatalogItems(input: {
  staffId: string;
  connectionId: string;
  businessRowId: string | null;
  businessId: string | null;
  categoryKey: string;
  items: Array<{ id: string; display: string; reference: string; code: string; type: string; active: string; raw_preview: Record<string, unknown> }>;
}) {
  const nowIso = new Date().toISOString();
  const rows = input.items.filter((item) => item.id).map((item) => ({
    sage_connection_id: input.connectionId,
    sage_business_row_id: input.businessRowId,
    sage_business_id: input.businessId,
    category_key: input.categoryKey,
    sage_external_id: item.id,
    display_name: item.display || item.id,
    reference_text: item.reference || null,
    code_text: item.code || null,
    sage_type: item.type || null,
    active_status: item.active || null,
    raw_preview_json: item.raw_preview,
    last_seen_at: nowIso,
    last_seen_by_staff_id: input.staffId,
    updated_at: nowIso,
  }));
  if (rows.length > 0) {
    await supabaseAdmin.from("sage_catalog_cache").upsert(rows, { onConflict: "sage_connection_id,sage_business_row_id,category_key,sage_external_id" });
  }
}
