"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/utils/supabase/server";
import { postCashBatchToSage } from "@/lib/sage/cashOutPosting";
import { postCustomerReceiptAllocationsToSage } from "@/lib/sage/cashAllocation";

type FreezeResult = {
  queue_row_id?: string | null;
  source_id?: string | null;
  snapshot_id?: string | null;
  freeze_status?: string | null;
  validation_status?: string | null;
  blocker?: string | null;
  posting_category?: string | null;
};

type BatchResult = {
  queue_row_id?: string | null;
  source_id?: string | null;
  snapshot_id?: string | null;
  batch_id?: string | null;
  batch_ref?: string | null;
  batch_status?: string | null;
  row_status?: string | null;
  blocker?: string | null;
  posting_category?: string | null;
};

type CashPostingResult = {
  posted: number;
  failed: number;
  needsReview: number;
  total: number;
  endpoint: string;
};

type SupersedeCashBatchResult = {
  batch_id?: string | null;
  batch_ref?: string | null;
  previous_status?: string | null;
  new_status?: string | null;
  cancelled_row_count?: number | null;
  deactivated_snapshot_count?: number | null;
  detail_href?: string | null;
};

const outPaymentCategories = new Set(["supplier_invoice_payment", "shipper_invoice_payment"]);
const controlCashCategories = new Set(["retailer_refund_received", "bank_fee", "fx_card_difference", "unmatched_hold"]);
const singleCategoryOnly = new Set([
  "customer_receipt_on_account",
  "retailer_refund_received",
  "bank_fee",
  "fx_card_difference",
  "unmatched_hold",
]);
const bankGlPostingCategories = new Set(["bank_fee", "fx_card_difference"]);

function formText(formData: FormData, key: string, fallback = "") {
  return String(formData.get(key) ?? fallback).trim();
}

function asStringArray(value: FormDataEntryValue[]) {
  return value.map((entry) => String(entry ?? "").trim()).filter(Boolean);
}

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function cashReturnPath(formData: FormData, messageKey: "success" | "error", message: string) {
  const qp = new URLSearchParams();
  const direction = formText(formData, "cash_direction", "all");
  const category = formText(formData, "cash_category", "all");
  const status = formText(formData, "cash_status", "all");
  const search = formText(formData, "cash_q", "");
  const pageSize = formText(formData, "cash_page_size", "100");

  if (direction) qp.set("direction", direction);
  if (category) qp.set("category", category);
  if (status) qp.set("status", status);
  if (search) qp.set("q", search);
  if (pageSize) qp.set("page_size", pageSize);
  qp.set(messageKey, message);

  return `/internal/accounting-command-centre/cash-posting?${qp.toString()}`;
}

async function originFromHeaders() {
  const headerStore = await headers();
  const host = headerStore.get("x-forwarded-host") || headerStore.get("host") || "";
  const proto = headerStore.get("x-forwarded-proto") || "https";
  return host ? `${proto}://${host}` : "";
}

async function requireAccountingAdminAccess() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirect(`/internal/accounting-command-centre/cash-posting?error=${encodeURIComponent(staffError?.message || "Active staff account required")}`);
  }

  const canAccess = String(staff.role_type ?? "") === "admin" || hasAccountingAdminTesting((staff as Record<string, unknown>).permissions_json);
  if (!canAccess) {
    redirect("/internal/accounting-command-centre/cash-posting?error=Accounting admin access required");
  }

  return { supabase, staffId: String(staff.id) };
}

function selectedQueueRows(formData: FormData) {
  const queueIds = asStringArray(formData.getAll("cash_queue_row_id"));
  if (queueIds.length > 0) return queueIds;
  return asStringArray(formData.getAll("cash_source_id")).map((id) => `cash:customer_receipt_on_account:${id}`);
}

function selectedCashCategories(selectedIds: string[]) {
  return Array.from(new Set(selectedIds.map((id) => id.split(":")[1] || "").filter(Boolean)));
}

function selectedRowsAreControlOnly(selectedIds: string[]) {
  const categories = selectedCashCategories(selectedIds);
  return categories.length > 0 && categories.every((category) => controlCashCategories.has(category));
}

function mixedCashSelectionError(selectedIds: string[]) {
  const categories = selectedCashCategories(selectedIds);
  if (categories.length <= 1) return "";

  const allOutPayments = categories.every((category) => outPaymentCategories.has(category));
  if (allOutPayments) return "";

  const namedCategories = categories.map((category) => category.replaceAll("_", " ")).join(", ");
  const hasSingleCategoryOnly = categories.some((category) => singleCategoryOnly.has(category));
  if (hasSingleCategoryOnly) {
    return `Do not mix ${namedCategories} in one cash batch. Filter to one category and create separate batches. Supplier/shipper OUT payments are the only supported mixed cash batch.`;
  }

  return `Do not mix ${namedCategories} in one cash batch. Filter to one category and create separate batches.`;
}

export async function freezeSelectedCustomerReceiptCashRowsAction(formData: FormData) {
  const selectedIds = selectedQueueRows(formData);

  if (selectedIds.length === 0) {
    redirect(cashReturnPath(formData, "error", "Select at least one ready cash row to freeze"));
  }

  const mixedError = mixedCashSelectionError(selectedIds);
  if (mixedError) {
    redirect(cashReturnPath(formData, "error", mixedError));
  }

  const { supabase } = await requireAccountingAdminAccess();
  const useControlRpc = selectedRowsAreControlOnly(selectedIds);

  const { data, error } = await (supabase as any).rpc(useControlRpc ? "internal_freeze_cash_control_rows_v1" : "internal_freeze_cash_posting_rows_v2", {
    p_queue_row_ids: selectedIds,
    p_notes: useControlRpc
      ? "Accounting Command Centre cash control freeze. No Sage API call. Live posting blocked until endpoint proof."
      : "Accounting Command Centre shared cash posting freeze. No Sage API call.",
  });

  if (error) redirect(cashReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const alreadyFrozenCount = rows.filter((row) => row.freeze_status === "already_frozen").length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen" && row.freeze_status !== "already_frozen").length;
  const categories = Array.from(new Set(rows.map((row) => row.posting_category).filter(Boolean)));
  const firstBlocker = rows.find((row) => row.blocker && row.freeze_status !== "already_frozen")?.blocker;

  revalidatePath("/internal/accounting-command-centre/cash-posting");

  const message = blockedCount > 0
    ? `Cash freeze: frozen ${frozenCount}, already frozen ${alreadyFrozenCount}, blocked ${blockedCount}${firstBlocker ? ` - ${firstBlocker}` : ""}`
    : `Cash freeze: frozen and validated ${frozenCount}; already frozen ${alreadyFrozenCount}; categories ${categories.join(", ") || "cash"}. No Sage API call was made.`;

  redirect(cashReturnPath(formData, blockedCount > 0 ? "error" : "success", message));
}

export async function createCustomerReceiptCashBatchAction(formData: FormData) {
  const selectedIds = selectedQueueRows(formData);

  if (selectedIds.length === 0) {
    redirect(cashReturnPath(formData, "error", "Select at least one frozen validated cash row to batch"));
  }

  const mixedError = mixedCashSelectionError(selectedIds);
  if (mixedError) {
    redirect(cashReturnPath(formData, "error", mixedError));
  }

  const { supabase } = await requireAccountingAdminAccess();
  const useControlRpc = selectedRowsAreControlOnly(selectedIds);

  const { data, error } = await (supabase as any).rpc(useControlRpc ? "internal_create_cash_control_batch_v1" : "internal_create_cash_batch_v2", {
    p_queue_row_ids: selectedIds,
    p_notes: useControlRpc
      ? "Accounting Command Centre cash control batch. No Sage API call. Live posting blocked until endpoint proof."
      : "Accounting Command Centre shared cash batch. No Sage API call.",
  });

  if (error) redirect(cashReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as BatchResult[]);
  const batchedCount = rows.filter((row) => row.row_status === "batched_validated" && row.batch_id).length;
  const alreadyBatchedCount = rows.filter((row) => row.row_status === "already_batched").length;
  const blockedCount = rows.filter((row) => row.row_status === "blocked" || row.row_status === "not_batched").length;
  const batchRefs = Array.from(new Set(rows.map((row) => row.batch_ref).filter(Boolean)));
  const categories = Array.from(new Set(rows.map((row) => row.posting_category).filter(Boolean)));
  const firstBlocker = rows.find((row) => row.blocker)?.blocker;

  revalidatePath("/internal/accounting-command-centre/cash-posting");

  const message = blockedCount > 0
    ? `Cash batch: batched ${batchedCount}, already batched ${alreadyBatchedCount}, blocked ${blockedCount}${firstBlocker ? ` - ${firstBlocker}` : ""}`
    : `Cash batch created: ${batchRefs.join(", ") || "validated batch"}; rows ${batchedCount}; already batched ${alreadyBatchedCount}; categories ${categories.join(", ") || "cash"}. No Sage API call was made.`;

  redirect(cashReturnPath(formData, blockedCount > 0 ? "error" : "success", message));
}

export async function postCustomerReceiptCashBatchAction(formData: FormData) {
  const batchId = formText(formData, "batch_id");
  if (!batchId) redirect("/internal/accounting-command-centre/cash-posting?error=Missing cash batch id");

  const { supabase, staffId } = await requireAccountingAdminAccess();
  const origin = await originFromHeaders();
  let result: CashPostingResult;

  if (process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true") {
    process.env.SAGE_LIVE_RETAILER_REFUND_IN_POSTING_ENABLED = "true";
  }

  try {
    const { data: batch, error: batchError } = await supabase
      .from("cash_posting_batches")
      .select("posting_category")
      .eq("id", batchId)
      .eq("active", true)
      .maybeSingle();

    if (batchError) throw new Error(batchError.message);

    const { data: batchRows, error: batchRowsError } = await supabase
      .from("cash_posting_batch_rows")
      .select("posting_category")
      .eq("batch_id", batchId)
      .eq("active", true);

    if (batchRowsError) throw new Error(batchRowsError.message);

    const { data: detailRows, error: detailError } = await (supabase as any).rpc("internal_cash_posting_batch_detail_v1", { p_batch_id: batchId });
    if (detailError) throw new Error(detailError.message);

    const batchCategory = String((batch as { posting_category?: unknown } | null)?.posting_category ?? "").trim();
    const directRowCategories = (batchRows ?? [])
      .map((row: { posting_category?: unknown }) => String(row.posting_category ?? "").trim())
      .filter(Boolean);
    const detailRowCategories = ((detailRows ?? []) as Array<{ posting_category?: unknown; batch_posting_category?: unknown }>)
      .map((row) => String(row.posting_category ?? row.batch_posting_category ?? "").trim())
      .filter(Boolean);
    const rowCategories = Array.from(new Set([...directRowCategories, ...detailRowCategories]));
    const effectiveCategory = rowCategories.length === 1 ? rowCategories[0] : batchCategory;
    const containsBankGlRows = rowCategories.some((category) => bankGlPostingCategories.has(category)) || bankGlPostingCategories.has(batchCategory);
    const containsNonBankGlRows = rowCategories.some((category) => !bankGlPostingCategories.has(category));

    if (containsBankGlRows && containsNonBankGlRows) {
      throw new Error(`Mixed bank/GL and non-bank/GL cash rows are not postable together. Batch category: ${batchCategory || "unknown"}. Row categories: ${rowCategories.join(", ") || "unknown"}.`);
    }

    if (effectiveCategory === "fx_card_difference") {
      const { postFxJournalCashBatchToSage } = await import("@/lib/sage/fxJournalPosting");
      result = await postFxJournalCashBatchToSage({ batchId, staffId, origin });
    } else if (bankGlPostingCategories.has(effectiveCategory) || (containsBankGlRows && !containsNonBankGlRows)) {
      const { postBankGlControlCashBatchToSage } = await import("@/lib/sage/bankGlPosting");
      result = await postBankGlControlCashBatchToSage({ batchId, staffId, origin });
    } else {
      result = await postCashBatchToSage({ batchId, staffId, origin });
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Cash Sage posting failed.";
    revalidatePath(`/internal/accounting-command-centre/cash-posting/batches/${batchId}`);
    redirect(`/internal/accounting-command-centre/cash-posting/batches/${batchId}?error=${encodeURIComponent(message)}`);
  }

  revalidatePath("/internal/accounting-command-centre/cash-posting");
  revalidatePath(`/internal/accounting-command-centre/cash-posting/batches/${batchId}`);
  redirect(`/internal/accounting-command-centre/cash-posting/batches/${batchId}?success=${encodeURIComponent(`Cash Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.needsReview} needs review, ${result.total} total. Endpoint ${result.endpoint}.`)}`);
}

export async function supersedeCashPostingBatchAction(formData: FormData) {
  const batchId = formText(formData, "batch_id");
  const reason = formText(formData, "supersede_reason", "Supersede local cash batch and re-freeze from current resolver.");
  if (!batchId) redirect("/internal/accounting-command-centre/cash-posting?error=Missing cash batch id");

  const { supabase } = await requireAccountingAdminAccess();
  const { data, error } = await (supabase as any).rpc("internal_supersede_cash_posting_batch_v1", {
    p_batch_id: batchId,
    p_reason: reason,
  });

  if (error) {
    revalidatePath(`/internal/accounting-command-centre/cash-posting/batches/${batchId}`);
    redirect(`/internal/accounting-command-centre/cash-posting/batches/${batchId}?error=${encodeURIComponent(error.message)}`);
  }

  const rows = ((data ?? []) as SupersedeCashBatchResult[]);
  const first = rows[0] ?? {};
  const batchRef = String(first.batch_ref ?? "cash batch");
  const cancelled = Number(first.cancelled_row_count ?? 0);
  const deactivated = Number(first.deactivated_snapshot_count ?? 0);

  revalidatePath("/internal/accounting-command-centre/cash-posting");
  revalidatePath(`/internal/accounting-command-centre/cash-posting/batches/${batchId}`);

  redirect(`/internal/accounting-command-centre/cash-posting?status=ready&success=${encodeURIComponent(`Superseded ${batchRef}: cancelled ${cancelled} row(s), deactivated ${deactivated} snapshot(s). Re-freeze from current resolver.`)}`);
}

export async function postSelectedCashAllocationsAction(formData: FormData) {
  const selectedIds = asStringArray(formData.getAll("cash_allocation_row_id"));
  if (selectedIds.length === 0) {
    redirect(cashReturnPath(formData, "error", "Select at least one ready cash allocation row"));
  }

  const { staffId } = await requireAccountingAdminAccess();
  const origin = await originFromHeaders();
  let result: Awaited<ReturnType<typeof postCustomerReceiptAllocationsToSage>>;

  try {
    result = await postCustomerReceiptAllocationsToSage({ cashBatchRowIds: selectedIds, staffId, origin });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Cash allocation posting failed.";
    revalidatePath("/internal/accounting-command-centre/cash-posting");
    redirect(cashReturnPath(formData, "error", message));
  }

  revalidatePath("/internal/accounting-command-centre/cash-posting");
  redirect(cashReturnPath(formData, "success", `Cash allocation posting finished: ${result.posted} allocated, ${result.failed} failed, ${result.total} total. Endpoint ${result.endpoint}.`));
}
