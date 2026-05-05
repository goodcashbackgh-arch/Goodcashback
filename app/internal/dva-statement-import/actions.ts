"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const FALLBACK_INVOICE_ID = "09ed41d2-4a3f-44fa-b292-ed1bdcd92735";
const STATEMENT_STORAGE_BUCKET = "invoice-evidence";
const VALID_SOURCE_BANKS = new Set(["gcb", "firstbank", "zenith", "other"]);
const VALID_FILE_TYPES = new Set(["pdf", "csv", "xlsx", "text", "unknown"]);

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-statement-import?${query.toString()}`);
}

function redirectToBatchWithResult(batchId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-statement-import/${batchId}?${query.toString()}`);
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

function detectStatementFileType(file: File) {
  const ext = safeExt(file.name);
  const mime = file.type.toLowerCase();

  if (mime.includes("pdf") || ext === "pdf") return "pdf";
  if (mime.includes("csv") || ext === "csv") return "csv";
  if (
    mime.includes("spreadsheet") ||
    mime.includes("excel") ||
    ext === "xlsx" ||
    ext === "xls"
  ) return "xlsx";
  if (mime.startsWith("text/") || ext === "txt" || ext === "text") return "text";
  return "unknown";
}

function readMoney(formData: FormData, key: string, fallback = 0) {
  const raw = readString(formData, key);
  if (!raw) return fallback;
  const value = Math.round(Number(raw) * 1000) / 1000;
  return Number.isFinite(value) && value >= 0 ? value : fallback;
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

export async function createRealStatementImportBatchAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ import_error: "Please sign in again before uploading a statement." });
  }

  const importerId = readString(formData, "importer_id");
  const sourceBank = readString(formData, "source_bank") || "other";
  const statementPeriodFrom = readString(formData, "statement_period_from");
  const statementPeriodTo = readString(formData, "statement_period_to");
  const localCcy = (readString(formData, "local_ccy") || "GBP").toUpperCase();
  const defaultCardMarkupPct = readMoney(formData, "default_card_markup_pct", 0);
  const fxSourceContext = readString(formData, "fx_source_context") || null;
  const notes = readString(formData, "notes") || null;
  const statementFile = formData.get("statement_file");

  if (!importerId) redirectWithResult({ import_error: "Select an importer before uploading the statement." });
  if (!VALID_SOURCE_BANKS.has(sourceBank)) redirectWithResult({ import_error: "Unsupported source bank." });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(statementPeriodFrom)) redirectWithResult({ import_error: "Statement period from date is required." });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(statementPeriodTo)) redirectWithResult({ import_error: "Statement period to date is required." });
  if (statementPeriodTo < statementPeriodFrom) redirectWithResult({ import_error: "Statement period to date cannot be before from date." });
  if (!/^[A-Z]{3}$/.test(localCcy)) redirectWithResult({ import_error: "Local currency must be a 3-letter currency code, e.g. GHS or GBP." });
  if (!(statementFile instanceof File) || statementFile.size <= 0) redirectWithResult({ import_error: "Statement file is required." });

  const detectedFileType = detectStatementFileType(statementFile);
  if (!VALID_FILE_TYPES.has(detectedFileType)) redirectWithResult({ import_error: "Unsupported statement file type." });

  const ext = safeExt(statementFile.name);
  const objectPath = `statement-imports/${importerId}/${Date.now()}.${ext}`;

  const { error: uploadError } = await supabase.storage
    .from(STATEMENT_STORAGE_BUCKET)
    .upload(objectPath, statementFile, {
      upsert: false,
      contentType: statementFile.type || undefined,
    });

  if (uploadError) {
    redirectWithResult({ import_error: `Statement upload failed. ${uploadError.message}` });
  }

  const { data: publicUrlData } = supabase.storage.from(STATEMENT_STORAGE_BUCKET).getPublicUrl(objectPath);
  const sourceFileUrl = publicUrlData.publicUrl || objectPath;

  const { data: batchResult, error: batchError } = await supabase.rpc("staff_create_dva_statement_import_batch", {
    p_importer_id: importerId,
    p_source_bank: sourceBank,
    p_statement_period_from: statementPeriodFrom,
    p_statement_period_to: statementPeriodTo,
    p_local_ccy: localCcy,
    p_source_file_url: sourceFileUrl,
    p_original_filename: statementFile.name,
    p_detected_file_type: detectedFileType,
    p_default_card_markup_pct: defaultCardMarkupPct,
    p_fx_source_context: fxSourceContext,
    p_notes: notes,
  });

  if (batchError) {
    redirectWithResult({ import_error: batchError.message });
  }

  revalidatePath("/internal/dva-statement-import");

  const importBatchId =
    typeof batchResult === "object" &&
    batchResult !== null &&
    "import_batch_id" in batchResult
      ? String((batchResult as { import_batch_id?: unknown }).import_batch_id)
      : "";
  const parserRoute =
    typeof batchResult === "object" &&
    batchResult !== null &&
    "parser_route" in batchResult
      ? String((batchResult as { parser_route?: unknown }).parser_route)
      : detectedFileType;

  redirectWithResult({
    import_success: `Statement uploaded and import batch created. Parser route: ${parserRoute}. Extraction is the next step.`,
    batch_id: importBatchId,
  });
}

export async function commitDvaStatementImportBatchAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const importBatchId = readString(formData, "import_batch_id");
  const notes = readString(formData, "notes") || "Committed clean statement rows from statement detail page.";

  if (!importBatchId) {
    redirectWithResult({ import_error: "Missing statement import batch id." });
  }

  if (!user) {
    redirectToBatchWithResult(importBatchId, { commit_error: "Please sign in again before committing statement rows." });
  }

  const { data: commitResult, error: commitError } = await supabase.rpc("staff_commit_dva_statement_import_batch", {
    p_import_batch_id: importBatchId,
    p_notes: notes,
  });

  if (commitError) {
    redirectToBatchWithResult(importBatchId, { commit_error: commitError.message });
  }

  revalidatePath("/internal/dva-statement-import");
  revalidatePath(`/internal/dva-statement-import/${importBatchId}`);
  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/funding");

  const committedCount =
    typeof commitResult === "object" &&
    commitResult !== null &&
    "committed_count" in commitResult
      ? String((commitResult as { committed_count?: unknown }).committed_count)
      : "0";

  redirectToBatchWithResult(importBatchId, {
    commit_success: `Committed ${committedCount} clean statement line(s). You can now open the matching workbench.`,
  });
}

export async function voidDvaStatementImportBatchAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const importBatchId = readString(formData, "import_batch_id");
  const voidReason = readString(formData, "void_reason");

  if (!importBatchId) {
    redirectWithResult({ import_error: "Missing statement import batch id." });
  }

  if (!user) {
    redirectWithResult({ import_error: "Please sign in again before voiding a statement import.", batch_id: importBatchId });
  }

  if (voidReason.length < 8) {
    redirectWithResult({ import_error: "Enter a void reason of at least 8 characters.", batch_id: importBatchId });
  }

  const { data: voidResult, error: voidError } = await supabase.rpc("staff_void_dva_statement_import_batch", {
    p_import_batch_id: importBatchId,
    p_void_reason: voidReason,
  });

  if (voidError) {
    redirectWithResult({ import_error: voidError.message, batch_id: importBatchId });
  }

  revalidatePath("/internal/dva-statement-import");
  revalidatePath(`/internal/dva-statement-import/${importBatchId}`);
  revalidatePath("/internal/dva-reconciliation");
  revalidatePath("/internal/dva-reconciliation/workspace");
  revalidatePath("/internal/dva-reconciliation/allocations");

  const linkedLines =
    typeof voidResult === "object" &&
    voidResult !== null &&
    "linked_lines_inactivated" in voidResult
      ? String((voidResult as { linked_lines_inactivated?: unknown }).linked_lines_inactivated)
      : "0";

  redirectWithResult({
    import_success: `Statement import voided. ${linkedLines} linked statement line(s) removed from active matching.`,
    batch_id: importBatchId,
  });
}

export async function createStageCommitSmokeImportAction(formData: FormData) {
  const importerId = "";

  try {
    await resolveImporterId(await createClient(), formData);
  } catch {
    // Intentionally ignored. The smoke-test path is disabled in production UI flow.
  }

  redirectWithResult({
    import_error: `Temporary smoke-test import is disabled. Use the real statement upload flow${importerId ? ` for importer ${importerId}` : ""}.`,
  });
}
