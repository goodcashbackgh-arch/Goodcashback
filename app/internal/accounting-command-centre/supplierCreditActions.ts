"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type FreezeResult = {
  snapshot_id?: string | null;
  freeze_status?: string | null;
  blocker?: string | null;
};

type BulkCandidate = {
  source_id?: string | null;
  excluded_reason?: string | null;
};

function asStringArray(value: FormDataEntryValue[]) {
  return value.map((entry) => String(entry ?? "").trim()).filter(Boolean);
}

function formText(formData: FormData, key: string, fallback = "") {
  return String(formData.get(key) ?? fallback).trim();
}

function boolForm(formData: FormData, key: string) {
  const raw = formText(formData, key).toLowerCase();
  return raw === "true" || raw === "on" || raw === "1" || raw === "yes";
}

function filteredReturnPath(formData: FormData, messageKey: "success" | "error", message: string) {
  const qp = new URLSearchParams();
  const queue = formText(formData, "bulk_queue", "actionable");
  const lane = formText(formData, "bulk_lane", "supplier_credit_note");
  const postingGate = formText(formData, "bulk_posting_gate", "all");
  const search = formText(formData, "bulk_q", "");
  const pageSize = formText(formData, "bulk_page_size", "50");

  if (queue) qp.set("queue", queue);
  if (lane) qp.set("lane", lane);
  if (postingGate) qp.set("posting_gate", postingGate);
  if (search) qp.set("q", search);
  if (pageSize) qp.set("page_size", pageSize);
  qp.set(messageKey, message);

  return `/internal/accounting-command-centre?${qp.toString()}`;
}

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
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
    redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(staffError?.message || "Active staff account required")}`);
  }

  const canAccess = String(staff.role_type ?? "") === "admin" || hasAccountingAdminTesting((staff as Record<string, unknown>).permissions_json);
  if (!canAccess) {
    redirect("/internal/accounting-command-centre?error=Accounting admin access required");
  }

  return supabase;
}

async function fetchMatchingSupplierCreditNoteCandidates(
  supabase: Awaited<ReturnType<typeof requireAccountingAdminAccess>>,
  formData: FormData,
) {
  const { data, error } = await (supabase as any).rpc("internal_accounting_command_centre_bulk_candidates_v1", {
    p_queue: formText(formData, "bulk_queue", "actionable"),
    p_lane: formText(formData, "bulk_lane", "supplier_credit_note"),
    p_posting_gate: formText(formData, "bulk_posting_gate", "all"),
    p_search: formText(formData, "bulk_q", "") || null,
    p_candidate_kind: "freeze",
    p_selection_group: "supplier_credit_note",
    p_include_warnings: boolForm(formData, "bulk_include_warnings"),
    p_max_rows: 5000,
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));
  return (data ?? []) as BulkCandidate[];
}

function frozenSnapshotIds(rows: FreezeResult[]) {
  return rows
    .filter((row) => row.freeze_status === "frozen" && row.snapshot_id)
    .map((row) => row.snapshot_id as string);
}

export async function freezeSelectedSupplierCreditNoteRowsAction(formData: FormData) {
  const singleId = formText(formData, "single_supplier_credit_submission_id", "");
  const selectedIds = singleId ? [singleId] : asStringArray(formData.getAll("supplier_credit_submission_id"));

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", "Select at least one supplier credit note row to freeze"));
  }

  const supabase = await requireAccountingAdminAccess();
  const { data, error } = await (supabase as any).rpc("internal_freeze_supplier_credit_note_sage_batch_v1", {
    p_refund_evidence_submission_ids: selectedIds,
    p_notes: singleId
      ? "Accounting command centre supplier credit note freeze single row"
      : "Accounting command centre supplier credit note freeze selected visible rows",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = (data ?? []) as FreezeResult[];
  const frozenCount = frozenSnapshotIds(rows).length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = blockedCount > 0
    ? `Supplier credit note ${singleId ? "single row" : "selected visible"}: frozen ${frozenCount} row(s); ${blockedCount} row(s) not frozen`
    : `Supplier credit note ${singleId ? "single row" : "selected visible"}: frozen and marked ready to post ${frozenCount} row(s)`;

  redirect(filteredReturnPath(formData, "success", message));
}

export async function freezeMatchingSupplierCreditNoteRowsAction(formData: FormData) {
  const supabase = await requireAccountingAdminAccess();
  const candidates = await fetchMatchingSupplierCreditNoteCandidates(supabase, formData);
  const included = candidates.filter((row) => !row.excluded_reason);
  const selectedIds = included.map((row) => String(row.source_id ?? "")).filter(Boolean);
  const excludedCount = candidates.length - included.length;

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", `No matching freezeable supplier credit note rows found; ${excludedCount} excluded`));
  }

  const { data, error } = await (supabase as any).rpc("internal_freeze_supplier_credit_note_sage_batch_v1", {
    p_refund_evidence_submission_ids: selectedIds,
    p_notes: "Accounting command centre supplier credit note freeze all matching filter",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = (data ?? []) as FreezeResult[];
  const frozenCount = frozenSnapshotIds(rows).length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  redirect(filteredReturnPath(formData, "success", `Supplier credit note all matching: frozen ${frozenCount}; ${blockedCount + excludedCount} excluded or not frozen`));
}
