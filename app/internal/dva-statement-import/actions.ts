"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const FALLBACK_INVOICE_ID = "09ed41d2-4a3f-44fa-b292-ed1bdcd92735";

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-statement-import?${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function todayIsoDate() {
  return new Date().toISOString().slice(0, 10);
}

async function resolveImporterId(supabase: Awaited<ReturnType<typeof createClient>>, formData: FormData) {
  const importerId = readString(formData, "importer_id");
  if (importerId) return importerId;

  const invoiceId = readString(formData, "base_supplier_invoice_id") || FALLBACK_INVOICE_ID;

  const { data: invoice, error: invoiceError } = await supabase
    .from("supplier_invoices")
    .select("order_id")
    .eq("id", invoiceId)
    .single();

  if (invoiceError || !invoice?.order_id) {
    throw new Error(invoiceError?.message || `Could not resolve order for supplier invoice ${invoiceId}`);
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("importer_id")
    .eq("id", invoice.order_id)
    .single();

  if (orderError || !order?.importer_id) {
    throw new Error(orderError?.message || `Could not resolve importer for order ${invoice.order_id}`);
  }

  return String(order.importer_id);
}

export async function createStageCommitSmokeImportAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ import_error: "Please sign in again before testing statement import." });
  }

  let importerId = "";

  try {
    importerId = await resolveImporterId(supabase, formData);
  } catch (error) {
    redirectWithResult({ import_error: error instanceof Error ? error.message : "Could not resolve importer for smoke import." });
  }

  const today = todayIsoDate();
  const amount = Number(readString(formData, "amount_gbp") || "44.44");
  const merchant = readString(formData, "merchant") || "SharkNinja Leeds GB";
  const merchantNormalised = readString(formData, "merchant_normalised") || "sharkninja";
  const fingerprint = `smoke-pdf-${importerId}-${Date.now()}`;
  const rawText = [
    today,
    "400149******5757 99999999",
    merchant,
    "603713102242",
    "137POSV26037089J",
    today,
    amount.toFixed(2),
    "TEST PDF-FIRST STATEMENT IMPORT SMOKE",
  ].join("\n");

  if (!Number.isFinite(amount) || amount <= 0) {
    redirectWithResult({ import_error: "Smoke amount must be greater than zero." });
  }

  const { data: batchResult, error: batchError } = await supabase.rpc("staff_create_dva_statement_import_batch", {
    p_importer_id: importerId,
    p_source_bank: "other",
    p_statement_period_from: today,
    p_statement_period_to: today,
    p_local_ccy: "GBP",
    p_source_file_url: `test://pdf-statement-smoke-${Date.now()}.pdf`,
    p_original_filename: "TEST-PDF-STATEMENT-SMOKE.pdf",
    p_detected_file_type: "pdf",
    p_default_card_markup_pct: 0,
    p_fx_source_context: "TEST ONLY: smoke import uses GBP no FX conversion",
    p_notes: "TEST ONLY: smoke import batch created from internal page",
  });

  if (batchError) {
    redirectWithResult({ import_error: batchError.message });
  }

  const importBatchId =
    typeof batchResult === "object" &&
    batchResult !== null &&
    "import_batch_id" in batchResult
      ? String((batchResult as { import_batch_id?: unknown }).import_batch_id)
      : "";

  if (!importBatchId) {
    redirectWithResult({ import_error: "Import batch RPC returned no import_batch_id." });
  }

  const { error: stageError } = await supabase.rpc("staff_stage_dva_statement_import_row", {
    p_import_batch_id: importBatchId,
    p_source_row_number: 1,
    p_source_page_number: 1,
    p_raw_text: rawText,
    p_raw_json: { smoke: true, source: "internal/dva-statement-import" },
    p_statement_date: today,
    p_transaction_date: today,
    p_direction: "out",
    p_transaction_type_candidate: "supplier_purchase_candidate",
    p_amount_local_ccy: amount,
    p_balance_after_local_ccy: null,
    p_local_ccy: "GBP",
    p_fx_rate_applied: 1,
    p_card_markup_pct_applied: 0,
    p_amount_gbp_equivalent: amount,
    p_card_last4: "5757",
    p_merchant_raw: merchant,
    p_merchant_normalised: merchantNormalised,
    p_bank_reference: "603713102242",
    p_auth_or_settlement_ref: "137POSV26037089J",
    p_transaction_family_ref: "SMOKE-PDF-FAMILY-001",
    p_parser_confidence: "high",
    p_error_code: null,
    p_error_message: null,
    p_statement_line_fingerprint_hash: fingerprint,
  });

  if (stageError) {
    redirectWithResult({ import_error: stageError.message });
  }

  const { data: commitResult, error: commitError } = await supabase.rpc("staff_commit_dva_statement_import_batch", {
    p_import_batch_id: importBatchId,
    p_notes: "TEST ONLY: committed smoke import row into active DVA statement lines",
  });

  if (commitError) {
    redirectWithResult({ import_error: commitError.message });
  }

  revalidatePath("/internal/dva-statement-import");
  revalidatePath("/internal/dva-reconciliation");

  const committedCount =
    typeof commitResult === "object" &&
    commitResult !== null &&
    "committed_count" in commitResult
      ? String((commitResult as { committed_count?: unknown }).committed_count)
      : "0";

  redirectWithResult({
    import_success: `Smoke import committed ${committedCount} statement line(s).`,
    batch_id: importBatchId,
  });
}
