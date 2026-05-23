"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/utils/supabase/server";
import { postCustomerReceiptCashBatchToSage } from "@/lib/sage/cashPosting";
import { postCustomerReceiptAllocationsToSage } from "@/lib/sage/cashAllocation";

type FreezeResult = {
  source_id?: string | null;
  snapshot_id?: string | null;
  freeze_status?: string | null;
  validation_status?: string | null;
  blocker?: string | null;
};

type BatchResult = {
  source_id?: string | null;
  snapshot_id?: string | null;
  batch_id?: string | null;
  batch_ref?: string | null;
  batch_status?: string | null;
  row_status?: string | null;
  blocker?: string | null;
};

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

export async function freezeSelectedCustomerReceiptCashRowsAction(formData: FormData) {
  const selectedIds = asStringArray(formData.getAll("cash_source_id"));

  if (selectedIds.length === 0) {
    redirect(cashReturnPath(formData, "error", "Select at least one ready customer/importer IN row to freeze"));
  }

  const { supabase } = await requireAccountingAdminAccess();

  const { data, error } = await (supabase as any).rpc("internal_freeze_customer_receipt_cash_posting_v1", {
    p_dva_reconciliation_ids: selectedIds,
    p_notes: "Accounting Command Centre cash posting freeze selected customer/importer IN rows. No Sage API call.",
  });

  if (error) redirect(cashReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const alreadyFrozenCount = rows.filter((row) => row.freeze_status === "already_frozen").length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen" && row.freeze_status !== "already_frozen").length;
  const firstBlocker = rows.find((row) => row.blocker && row.freeze_status !== "already_frozen")?.blocker;

  revalidatePath("/internal/accounting-command-centre/cash-posting");

  const message = blockedCount > 0
    ? `Customer IN cash freeze: frozen ${frozenCount}, already frozen ${alreadyFrozenCount}, blocked ${blockedCount}${firstBlocker ? ` — ${firstBlocker}` : ""}`
    : `Customer IN cash freeze: frozen and validated ${frozenCount}; already frozen ${alreadyFrozenCount}. No Sage API call was made.`;

  redirect(cashReturnPath(formData, blockedCount > 0 ? "error" : "success", message));
}

export async function createCustomerReceiptCashBatchAction(formData: FormData) {
  const selectedIds = asStringArray(formData.getAll("cash_source_id"));

  if (selectedIds.length === 0) {
    redirect(cashReturnPath(formData, "error", "Select at least one frozen validated customer/importer IN row to batch"));
  }

  const { supabase } = await requireAccountingAdminAccess();

  const { data, error } = await (supabase as any).rpc("internal_create_customer_receipt_cash_batch_v1", {
    p_source_ids: selectedIds,
    p_notes: "Accounting Command Centre customer/importer IN cash batch. No Sage API call.",
  });

  if (error) redirect(cashReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as BatchResult[]);
  const batchedCount = rows.filter((row) => row.row_status === "batched_validated" && row.batch_id).length;
  const alreadyBatchedCount = rows.filter((row) => row.row_status === "already_batched").length;
  const blockedCount = rows.filter((row) => row.row_status === "blocked" || row.row_status === "not_batched").length;
  const batchRefs = Array.from(new Set(rows.map((row) => row.batch_ref).filter(Boolean)));
  const firstBlocker = rows.find((row) => row.blocker)?.blocker;

  revalidatePath("/internal/accounting-command-centre/cash-posting");

  const message = blockedCount > 0
    ? `Customer IN cash batch: batched ${batchedCount}, already batched ${alreadyBatchedCount}, blocked ${blockedCount}${firstBlocker ? ` — ${firstBlocker}` : ""}`
    : `Customer IN cash batch created: ${batchRefs.join(", ") || "validated batch"}; rows ${batchedCount}; already batched ${alreadyBatchedCount}. No Sage API call was made.`;

  redirect(cashReturnPath(formData, blockedCount > 0 ? "error" : "success", message));
}

export async function postCustomerReceiptCashBatchAction(formData: FormData) {
  const batchId = formText(formData, "batch_id");
  if (!batchId) redirect("/internal/accounting-command-centre/cash-posting?error=Missing cash batch id");

  const { staffId } = await requireAccountingAdminAccess();
  const origin = await originFromHeaders();
  let result: Awaited<ReturnType<typeof postCustomerReceiptCashBatchToSage>>;

  try {
    result = await postCustomerReceiptCashBatchToSage({ batchId, staffId, origin });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Customer receipt Sage posting failed.";
    revalidatePath(`/internal/accounting-command-centre/cash-posting/batches/${batchId}`);
    redirect(`/internal/accounting-command-centre/cash-posting/batches/${batchId}?error=${encodeURIComponent(message)}`);
  }

  revalidatePath("/internal/accounting-command-centre/cash-posting");
  revalidatePath(`/internal/accounting-command-centre/cash-posting/batches/${batchId}`);
  redirect(`/internal/accounting-command-centre/cash-posting/batches/${batchId}?success=${encodeURIComponent(`Customer receipt Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.needsReview} needs review, ${result.total} total. Endpoint ${result.endpoint}.`)}`);
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
