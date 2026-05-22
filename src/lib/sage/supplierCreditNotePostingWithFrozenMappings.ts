import { supabaseAdmin } from "@/lib/supabase/admin";
import { postSupplierCreditNoteBatchToSage as postBaseSupplierCreditNoteBatchToSage } from "@/lib/sage/supplierCreditNotePosting";

type Row = Record<string, any>;

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function mappingValue(payload: Row, code: string) {
  const direct = asObject(asObject(payload.mapping_snapshot)[code]);
  const nested = asObject(asObject(asObject(payload.source_payload).mapping_snapshot)[code]);
  return text(direct.sage_external_id) || text(nested.sage_external_id);
}

function patchPayload(payload: Row) {
  const ledger = mappingValue(payload, "SUPPLIER_GOODS_AP_LEDGER");
  const tax = mappingValue(payload, "SUPPLIER_GOODS_AP_TAX_RATE");
  if (!ledger && !tax) return payload;

  const lines = Array.isArray(payload.resolved_lines) ? payload.resolved_lines : [];
  return {
    ...payload,
    resolved_lines: lines.map((lineRaw) => {
      const line = asObject(lineRaw);
      return {
        ...line,
        ...(ledger ? { sage_ledger_account_id: ledger, resolved_ledger_account_id: ledger } : {}),
        ...(tax ? { sage_tax_rate_id: tax, tax_rate_id: tax, resolved_tax_rate_id: tax } : {}),
      };
    }),
  };
}

async function applyFrozenApMappingsToSupplierCreditNoteRows(batchId: string) {
  const { data: rows, error } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("id, request_payload_json")
    .eq("batch_id", batchId)
    .eq("document_lane", "supplier_credit_note")
    .is("sage_object_id", null)
    .in("posting_status", ["included", "validated", "failed_retryable", "failed_terminal"]);

  if (error) throw new Error(error.message);

  for (const row of rows ?? []) {
    const patched = patchPayload(asObject((row as Row).request_payload_json));
    await supabaseAdmin
      .from("sage_posting_batch_rows")
      .update({ request_payload_json: patched })
      .eq("id", (row as Row).id);
  }
}

export async function postSupplierCreditNoteBatchToSage(params: {
  batchId: string;
  staffId: string;
  origin: string;
}) {
  await applyFrozenApMappingsToSupplierCreditNoteRows(params.batchId);
  return postBaseSupplierCreditNoteBatchToSage(params);
}
