import "server-only";

import { supabaseAdmin } from "@/lib/supabase/admin";

type SavedItem = { id: string; display: string; reference: string; code: string; type: string; active: string; raw_preview: Record<string, unknown> };
type SavedCategory = { key: string; label: string; endpoint: string; ok: boolean; http_status: number | null; count: number; items: SavedItem[]; error: string | null };

function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function objectValue(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Record<string, unknown>;
}

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
  items: SavedItem[];
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

export async function saveCatalogSnapshot(staffId: string, discovery: any) {
  if (!discovery?.ok || !discovery?.connection?.id) return;
  for (const category of discovery.categories ?? []) {
    await writeSavedCatalogCategory({
      staffId,
      connectionId: discovery.connection.id,
      businessRowId: discovery.business?.id ?? null,
      businessId: discovery.business?.sage_business_id ?? null,
      categoryKey: category.key,
      categoryLabel: category.label,
      endpointPath: category.endpoint,
      httpStatus: category.http_status,
      ok: category.ok,
      rowCount: category.count,
      lastError: category.error,
    });
    await writeSavedCatalogItems({
      staffId,
      connectionId: discovery.connection.id,
      businessRowId: discovery.business?.id ?? null,
      businessId: discovery.business?.sage_business_id ?? null,
      categoryKey: category.key,
      items: category.items ?? [],
    });
  }
}

export async function getSavedCatalogSnapshot(connectionId: string, businessRowId: string | null) {
  const categoryBase = supabaseAdmin
    .from("sage_catalog_category_cache")
    .select("category_key, category_label, endpoint_path, ok, http_status, row_count, last_error, last_seen_at")
    .eq("sage_connection_id", connectionId)
    .order("category_key", { ascending: true });
  const { data: categoryRows, error } = businessRowId
    ? await categoryBase.eq("sage_business_row_id", businessRowId)
    : await categoryBase.is("sage_business_row_id", null);
  if (error || !categoryRows?.length) return null;

  const itemBase = supabaseAdmin
    .from("sage_catalog_cache")
    .select("category_key, sage_external_id, display_name, reference_text, code_text, sage_type, active_status, raw_preview_json")
    .eq("sage_connection_id", connectionId)
    .order("display_name", { ascending: true });
  const { data: itemRows } = businessRowId
    ? await itemBase.eq("sage_business_row_id", businessRowId)
    : await itemBase.is("sage_business_row_id", null);

  const items = (itemRows ?? []) as Record<string, unknown>[];
  const categories = (categoryRows as Record<string, unknown>[]).map((category) => {
    const key = text(category.category_key);
    const categoryItems = items.filter((item) => text(item.category_key) === key).slice(0, 100).map((item) => ({
      id: text(item.sage_external_id),
      display: text(item.display_name),
      reference: text(item.reference_text),
      code: text(item.code_text),
      type: text(item.sage_type),
      active: text(item.active_status),
      raw_preview: objectValue(item.raw_preview_json),
    }));
    return {
      key,
      label: text(category.category_label),
      endpoint: text(category.endpoint_path),
      ok: Boolean(category.ok),
      http_status: Number(category.http_status) || null,
      count: Number(category.row_count) || categoryItems.length,
      items: categoryItems,
      error: text(category.last_error) || null,
    } as SavedCategory;
  });
  return { categories, cachedAt: (categoryRows as Record<string, unknown>[]).map((row) => text(row.last_seen_at)).sort().reverse()[0] ?? null };
}

export async function getLatestSavedCatalogSnapshot() {
  const { data: connection } = await supabaseAdmin
    .from("sage_connections")
    .select("id")
    .in("status", ["connected", "token_expired", "refresh_failed"])
    .order("updated_at", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!connection?.id) return null;
  const { data: business } = await supabaseAdmin
    .from("sage_businesses")
    .select("id")
    .eq("connection_id", connection.id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  return getSavedCatalogSnapshot(String(connection.id), business?.id ? String(business.id) : null);
}
