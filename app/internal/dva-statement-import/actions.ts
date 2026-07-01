"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const STATEMENT_STORAGE_BUCKET = "invoice-evidence";
const VALID_SOURCE_BANKS = new Set(["gcb", "firstbank", "zenith", "other"]);
const VALID_FILE_TYPES = new Set(["pdf", "csv", "xlsx", "text", "unknown"]);
const VALID_ACCOUNT_CONTEXTS = new Set(["importer_dva_card_account", "main_company_bank_account"]);
const VALID_STATEMENT_SOURCE_WALLETS = new Set(["dva_cash", "dva_ghs_wallet", "virtual_gbp_wallet"]);

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

function checked(formData: FormData, key: string) {
  const value = formData.get(key);
  return value === "on" || value === "true" || value === "1";
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

function statementSourceLabel(value: string) {
  if (value === "dva_ghs_wallet") return "Loyalty DVA GHS wallet";
  if (value === "virtual_gbp_wallet") return "Loyalty virtual GBP wallet";
  return "Real DVA cash";
}

export async function createRealStatementImportBatchAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ import_error: "Please sign in again before uploading a statement." });
  }

  const statementAccountContext = readString(formData, "statement_account_context") || "importer_dva_card_account";
  const importerId = readString(formData, "importer_id");
  const sourceBank = readString(formData, "source_bank") || "other";
  const statementSourceWalletCode = readString(formData, "statement_source_wallet_code") || "dva_cash";
  const statementPeriodFrom = readString(formData, "statement_period_from");
  const statementPeriodTo = readString(formData, "statement_period_to");
  const statementAlreadyGbp = checked(formData, "statement_already_gbp");
  const rawLocalCcy = (readString(formData, "local_ccy") || "GBP").toUpperCase();
  const localCcy = statementAlreadyGbp ? "GBP" : rawLocalCcy;
  const defaultCardMarkupPct = statementAlreadyGbp ? 0 : readMoney(formData, "default_card_markup_pct", 0);
  const rawFxSourceContext = readString(formData, "fx_source_context");
  const fxSourceContext = statementAlreadyGbp
    ? "GBP statement - no FX conversion or settlement-card markup applied."
    : rawFxSourceContext || null;
  const notes = readString(formData, "notes") || null;
  const statementFile = formData.get("statement_file");

  if (!VALID_ACCOUNT_CONTEXTS.has(statementAccountContext)) redirectWithResult({ import_error: "Unsupported statement account type." });
  if (statementAccountContext === "importer_dva_card_account" && !importerId) redirectWithResult({ import_error: "Select an importer before uploading an importer DVA/card statement." });
  if (!VALID_SOURCE_BANKS.has(sourceBank)) redirectWithResult({ import_error: "Unsupported source bank." });
  if (statementAccountContext === "importer_dva_card_account" && !VALID_STATEMENT_SOURCE_WALLETS.has(statementSourceWalletCode)) redirectWithResult({ import_error: "Unsupported statement source." });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(statementPeriodFrom)) redirectWithResult({ import_error: "Statement period from date is required." });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(statementPeriodTo)) redirectWithResult({ import_error: "Statement period to date is required." });
  if (statementPeriodTo < statementPeriodFrom) redirectWithResult({ import_error: "Statement period to date cannot be before from date." });
  if (!/^[A-Z]{3}$/.test(localCcy)) redirectWithResult({ import_error: "Local currency must be a 3-letter currency code, e.g. GHS or GBP." });
  if (!(statementFile instanceof File) || statementFile.size <= 0) redirectWithResult({ import_error: "Statement file is required." });

  const detectedFileType = detectStatementFileType(statementFile);
  if (!VALID_FILE_TYPES.has(detectedFileType)) redirectWithResult({ import_error: "Unsupported statement file type." });

  const ext = safeExt(statementFile.name);
  const statementAccountKey = statementAccountContext === "main_company_bank_account" ? "main-company-bank" : importerId;
  const objectPath = `statement-imports/${statementAccountKey}/${Date.now()}.${ext}`;

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

  const rpcName = statementAccountContext === "main_company_bank_account"
    ? "staff_create_dva_statement_import_batch_with_context_v1"
    : "staff_create_dva_statement_import_batch";

  const rpcArgs = statementAccountContext === "main_company_bank_account"
    ? {
        p_statement_account_context: statementAccountContext,
        p_importer_id: null,
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
        p_statement_source_wallet_code: null,
      }
    : {
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
        p_statement_source_wallet_code: statementSourceWalletCode,
      };

  const { data: batchResult, error: batchError } = await supabase.rpc(rpcName, rpcArgs);

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
  const accountLabel = statementAccountContext === "main_company_bank_account" ? "Main company bank" : "Importer DVA/card";
  const sourceLabel = statementAccountContext === "main_company_bank_account" ? "main company bank" : statementSourceLabel(statementSourceWalletCode);
  const gbpNote = statementAlreadyGbp ? " No FX conversion was applied." : "";

  redirectWithResult({
    import_success: `${accountLabel} statement uploaded as ${sourceLabel} and import batch created. Parser route: ${parserRoute}.${gbpNote} Extraction is the next step.`,
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

export async function resetDvaStatementImportBatchAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const importBatchId = readString(formData, "import_batch_id");
  const resetReason = readString(formData, "reset_reason") || "Reset staged rows before commit.";

  if (!importBatchId) {
    redirectWithResult({ import_error: "Missing statement import batch id." });
  }

  if (!user) {
    redirectToBatchWithResult(importBatchId, { reset_error: "Please sign in again before resetting statement rows." });
  }

  const { data: resetResult, error: resetError } = await supabase.rpc("staff_reset_dva_statement_import_batch", {
    p_import_batch_id: importBatchId,
    p_reset_reason: resetReason,
  });

  if (resetError) {
    redirectToBatchWithResult(importBatchId, { reset_error: resetError.message });
  }

  revalidatePath("/internal/dva-statement-import");
  revalidatePath(`/internal/dva-statement-import/${importBatchId}`);
  revalidatePath("/internal/dva-statement-import/mindee-control");

  const deletedRows =
    typeof resetResult === "object" &&
    resetResult !== null &&
    "deleted_rows" in resetResult
      ? String((resetResult as { deleted_rows?: unknown }).deleted_rows)
      : "0";

  redirectToBatchWithResult(importBatchId, {
    reset_success: `Reset ${deletedRows} staged row(s). You can parse/stage again after fixing FX or parser inputs.`,
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
    import_success: `Voided import batch. ${linkedLines} linked statement line(s) were marked inactive.`,
    batch_id: importBatchId,
    batch_status: "audit",
  });
}
