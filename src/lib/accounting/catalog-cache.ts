import "server-only";

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
