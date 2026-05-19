"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type FreezeResult = {
  snapshot_id?: string | null;
  sales_invoice_id?: string | null;
  supplier_invoice_id?: string | null;
  shipping_document_id?: string | null;
  freeze_status?: string | null;
  blocker?: string | null;
};

type BulkCandidate = {
  candidate_kind?: string | null;
  selection_group?: string | null;
  source_id?: string | null;
  snapshot_id?: string | null;
  amount_gbp?: number | string | null;
  excluded_reason?: string | null;
};

type CreateBatchResult = {
  batch_id?: string | null;
  batch_ref?: string | null;
  included_count?: number | string | null;
  excluded_count?: number | string | null;
  total_amount_gbp?: number | string | null;
  detail_href?: string | null;
};

type DryRunValidationResult = {
  row_id?: string | null;
  payload_validation_status?: string | null;
  error_code?: string | null;
};

type SupersedeBatchResult = {
  batch_id?: string | null;
  batch_ref?: string | null;
  cancelled_row_count?: number | string | null;
  deactivated_snapshot_count?: number | string | null;
};

type SelectionGroup = "customer_sales" | "supplier_goods_ap" | "shipper_ap" | "all";

type RefreezePayload = {
  document_lane?: string | null;
  source_id?: string | null;
  source_table?: string | null;
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
  const lane = formText(formData, "bulk_lane", "all");
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

function parseRefreezePayload(formData: FormData): RefreezePayload {
  const raw = formText(formData, "refreeze_payload", "");
  if (!raw) return {};

  try {
    const parsed = JSON.parse(raw) as RefreezePayload;
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
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

async function revalidateFrozenSnapshots(supabase: Awaited<ReturnType<typeof requireAccountingAdminAccess>>, snapshotIds: string[], formData?: FormData) {
  if (snapshotIds.length === 0) return;

  const { error: revalidateError } = await (supabase as any).rpc("internal_revalidate_sage_posting_snapshots_v1", {
    p_snapshot_ids: snapshotIds,
  });

  if (revalidateError) {
    const message = `Frozen but revalidation failed: ${revalidateError.message}`;
    redirect(formData ? filteredReturnPath(formData, "error", message) : `/internal/accounting-command-centre?error=${encodeURIComponent(message)}`);
  }
}

async function fetchMatchingCandidates(
  supabase: Awaited<ReturnType<typeof requireAccountingAdminAccess>>,
  formData: FormData,
  candidateKind: "freeze" | "revalidate",
  selectionGroup: SelectionGroup,
) {
  const { data, error } = await (supabase as any).rpc("internal_accounting_command_centre_bulk_candidates_v1", {
    p_queue: formText(formData, "bulk_queue", "actionable"),
    p_lane: formText(formData, "bulk_lane", "all"),
    p_posting_gate: formText(formData, "bulk_posting_gate", "all"),
    p_search: formText(formData, "bulk_q", "") || null,
    p_candidate_kind: candidateKind,
    p_selection_group: selectionGroup,
    p_include_warnings: boolForm(formData, "bulk_include_warnings"),
    p_max_rows: 5000,
  });

  if (error) {
    redirect(filteredReturnPath(formData, "error", error.message));
  }

  return ((data ?? []) as BulkCandidate[]);
}

function includedCandidates(rows: BulkCandidate[]) {
  return rows.filter((row) => !row.excluded_reason);
}

function frozenSnapshotIds(rows: FreezeResult[]) {
  return rows
    .filter((row) => row.freeze_status === "frozen" && row.snapshot_id)
    .map((row) => row.snapshot_id as string);
}

export async function freezeSelectedCustomerSalesRowsAction(formData: FormData) {
  const selectedIds = asStringArray(formData.getAll("sales_invoice_id"));

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", "Select at least one customer sales row to freeze"));
  }

  const supabase = await requireAccountingAdminAccess();

  const { data, error } = await (supabase as any).rpc("internal_freeze_customer_sales_sage_batch_v1", {
    p_sales_invoice_ids: selectedIds,
    p_notes: "Accounting command centre customer sales freeze selected visible rows",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const snapshotIds = frozenSnapshotIds(rows);
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  await revalidateFrozenSnapshots(supabase, snapshotIds, formData);

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = blockedCount > 0
    ? `Customer sales selected visible: frozen ${snapshotIds.length} row(s); ${blockedCount} row(s) not frozen`
    : `Customer sales selected visible: frozen and revalidated ${snapshotIds.length} row(s)`;

  redirect(filteredReturnPath(formData, "success", message));
}

export async function freezeMatchingCustomerSalesRowsAction(formData: FormData) {
  const supabase = await requireAccountingAdminAccess();
  const candidates = await fetchMatchingCandidates(supabase, formData, "freeze", "customer_sales");
  const included = includedCandidates(candidates);
  const selectedIds = included.map((row) => String(row.source_id ?? "")).filter(Boolean);
  const excludedCount = candidates.length - included.length;

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", `No matching freezeable customer sales rows found; ${excludedCount} excluded`));
  }

  const { data, error } = await (supabase as any).rpc("internal_freeze_customer_sales_sage_batch_v1", {
    p_sales_invoice_ids: selectedIds,
    p_notes: "Accounting command centre customer sales freeze all matching filter",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const snapshotIds = frozenSnapshotIds(rows);
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  await revalidateFrozenSnapshots(supabase, snapshotIds, formData);

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = `Customer sales all matching: frozen/revalidated ${snapshotIds.length}; ${blockedCount + excludedCount} excluded or not frozen`;
  redirect(filteredReturnPath(formData, "success", message));
}

export async function freezeSelectedSupplierGoodsApRowsAction(formData: FormData) {
  const singleId = formText(formData, "single_supplier_invoice_id", "");
  const selectedIds = singleId ? [singleId] : asStringArray(formData.getAll("supplier_invoice_id"));

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", "Select at least one supplier goods AP row to freeze"));
  }

  const supabase = await requireAccountingAdminAccess();

  const { data, error } = await (supabase as any).rpc("internal_freeze_supplier_goods_ap_sage_batch_v1", {
    p_supplier_invoice_ids: selectedIds,
    p_notes: singleId
      ? "Accounting command centre supplier goods AP freeze single row"
      : "Accounting command centre supplier goods AP freeze selected visible rows",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = blockedCount > 0
    ? `Supplier goods AP ${singleId ? "single row" : "selected visible"}: frozen ${frozenCount} row(s); ${blockedCount} row(s) not frozen`
    : `Supplier goods AP ${singleId ? "single row" : "selected visible"}: frozen and marked ready to post ${frozenCount} row(s)`;

  redirect(filteredReturnPath(formData, "success", message));
}

export async function freezeMatchingSupplierGoodsApRowsAction(formData: FormData) {
  const supabase = await requireAccountingAdminAccess();
  const candidates = await fetchMatchingCandidates(supabase, formData, "freeze", "supplier_goods_ap");
  const included = includedCandidates(candidates);
  const selectedIds = included.map((row) => String(row.source_id ?? "")).filter(Boolean);
  const excludedCount = candidates.length - included.length;

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", `No matching freezeable supplier goods AP rows found; ${excludedCount} excluded`));
  }

  const { data, error } = await (supabase as any).rpc("internal_freeze_supplier_goods_ap_sage_batch_v1", {
    p_supplier_invoice_ids: selectedIds,
    p_notes: "Accounting command centre supplier goods AP freeze all matching filter",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = `Supplier goods AP all matching: frozen ${frozenCount}; ${blockedCount + excludedCount} excluded or not frozen`;
  redirect(filteredReturnPath(formData, "success", message));
}

export async function freezeSelectedShipperApRowsAction(formData: FormData) {
  const selectedIds = asStringArray(formData.getAll("shipping_document_id"));

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", "Select at least one shipper AP row to freeze"));
  }

  const supabase = await requireAccountingAdminAccess();

  const { data, error } = await (supabase as any).rpc("internal_freeze_shipper_ap_sage_batch_v1", {
    p_shipping_document_ids: selectedIds,
    p_notes: "Accounting command centre shipper AP freeze selected visible rows",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = blockedCount > 0
    ? `Shipper AP selected visible: frozen ${frozenCount} row(s); ${blockedCount} row(s) not frozen`
    : `Shipper AP selected visible: frozen and marked ready to post ${frozenCount} row(s)`;

  redirect(filteredReturnPath(formData, "success", message));
}

export async function freezeMatchingShipperApRowsAction(formData: FormData) {
  const supabase = await requireAccountingAdminAccess();
  const candidates = await fetchMatchingCandidates(supabase, formData, "freeze", "shipper_ap");
  const included = includedCandidates(candidates);
  const selectedIds = included.map((row) => String(row.source_id ?? "")).filter(Boolean);
  const excludedCount = candidates.length - included.length;

  if (selectedIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", `No matching freezeable shipper AP rows found; ${excludedCount} excluded`));
  }

  const { data, error } = await (supabase as any).rpc("internal_freeze_shipper_ap_sage_batch_v1", {
    p_shipping_document_ids: selectedIds,
    p_notes: "Accounting command centre shipper AP freeze all matching filter",
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = `Shipper AP all matching: frozen ${frozenCount}; ${blockedCount + excludedCount} excluded or not frozen`;
  redirect(filteredReturnPath(formData, "success", message));
}

export async function revalidateMatchingFrozenRowsAction(formData: FormData) {
  const supabase = await requireAccountingAdminAccess();
  const candidates = await fetchMatchingCandidates(supabase, formData, "revalidate", "all");
  const included = includedCandidates(candidates);
  const snapshotIds = included.map((row) => String(row.snapshot_id ?? "")).filter(Boolean);
  const excludedCount = candidates.length - included.length;

  if (snapshotIds.length === 0) {
    redirect(filteredReturnPath(formData, "error", `No matching frozen snapshots to revalidate; ${excludedCount} excluded`));
  }

  const { error } = await (supabase as any).rpc("internal_revalidate_sage_posting_snapshots_v1", {
    p_snapshot_ids: snapshotIds,
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  redirect(filteredReturnPath(formData, "success", `Revalidated ${snapshotIds.length} matching frozen snapshot(s); ${excludedCount} excluded`));
}

export async function createPostingBatchFromMatchingRowsAction(formData: FormData) {
  const supabase = await requireAccountingAdminAccess();
  const { data, error } = await (supabase as any).rpc("internal_create_sage_posting_batch_from_filter_v1", {
    p_queue: formText(formData, "bulk_queue", "frozen_ready_to_post"),
    p_lane: formText(formData, "bulk_lane", "all"),
    p_posting_gate: formText(formData, "bulk_posting_gate", "ready_to_post"),
    p_search: formText(formData, "bulk_q", "") || null,
    p_include_warnings: boolForm(formData, "bulk_include_warnings"),
    p_notes: "Accounting Command Centre batch creation. No Sage API call. Posting disabled until Sage OAuth and dry-run validation are proven.",
    p_max_rows: 5000,
  });

  if (error) redirect(filteredReturnPath(formData, "error", error.message));

  const result = ((data ?? []) as CreateBatchResult[])[0];
  if (!result?.batch_id) {
    redirect(filteredReturnPath(formData, "error", "Posting batch was not created."));
  }

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${result.batch_id}`);
  redirect(result.detail_href || `/internal/accounting-command-centre/batches/${result.batch_id}`);
}

export async function validateSagePostingBatchPayloadsAction(formData: FormData) {
  const batchId = formText(formData, "batch_id", "");
  if (!batchId) {
    redirect("/internal/accounting-command-centre?error=Missing posting batch id");
  }

  const supabase = await requireAccountingAdminAccess();
  const { data, error } = await (supabase as any).rpc("internal_validate_sage_posting_batch_payloads_v1", {
    p_batch_id: batchId,
  });

  if (error) {
    redirect(`/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(error.message)}`);
  }

  const rows = ((data ?? []) as DryRunValidationResult[]);
  const ok = rows.filter((row) => row.payload_validation_status === "dry_run_validated").length;
  const failed = rows.filter((row) => row.payload_validation_status === "dry_run_failed").length;
  const excluded = rows.filter((row) => row.payload_validation_status === "excluded_before_validation").length;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);

  redirect(`/internal/accounting-command-centre/batches/${batchId}?success=${encodeURIComponent(`Dry-run validation complete: ${ok} valid, ${failed} failed, ${excluded} excluded. No Sage object was created.`)}`);
}

export async function supersedeLocalSagePostingBatchAction(formData: FormData) {
  const batchId = formText(formData, "batch_id", "");
  const reason = formText(formData, "reason", "Superseded to re-freeze from current Sage resolver/payload builder");
  if (!batchId) {
    redirect("/internal/accounting-command-centre?error=Missing posting batch id");
  }

  const supabase = await requireAccountingAdminAccess();
  const { data, error } = await (supabase as any).rpc("internal_supersede_sage_posting_batch_v1", {
    p_batch_id: batchId,
    p_reason: reason,
  });

  if (error) {
    redirect(`/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(error.message)}`);
  }

  const result = ((data ?? []) as SupersedeBatchResult[])[0];
  const batchRef = result?.batch_ref || "batch";
  const rows = result?.cancelled_row_count ?? 0;
  const snapshots = result?.deactivated_snapshot_count ?? 0;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);

  redirect(`/internal/accounting-command-centre?queue=live_ready_not_frozen&success=${encodeURIComponent(`Superseded ${batchRef}: cancelled ${rows} row(s), deactivated ${snapshots} snapshot(s). Re-freeze from current resolver.`)}`);
}

export async function refreezeSourceFromBatchHistoryAction(formData: FormData) {
  const payload = parseRefreezePayload(formData);
  const lane = String(payload.document_lane ?? "").trim();
  const sourceId = String(payload.source_id ?? "").trim();
  const sourceTable = String(payload.source_table ?? "").trim();

  if (!sourceId || !lane) {
    redirect("/internal/accounting-command-centre?error=Missing source to re-freeze");
  }

  const expectedSourceTable: Record<string, string> = {
    customer_sales: "sales_invoices",
    supplier_goods_ap: "supplier_invoices",
    shipper_ap: "shipping_documents",
  };

  if (!expectedSourceTable[lane] || (sourceTable && sourceTable !== expectedSourceTable[lane])) {
    redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(`Cannot re-freeze unsupported source ${sourceTable || "unknown"}/${lane || "unknown"}`)}`);
  }

  const supabase = await requireAccountingAdminAccess();
  let rows: FreezeResult[] = [];

  if (lane === "customer_sales") {
    const { data, error } = await (supabase as any).rpc("internal_freeze_customer_sales_sage_batch_v1", {
      p_sales_invoice_ids: [sourceId],
      p_notes: "Accounting command centre re-freeze source from cancelled/superseded batch history",
    });
    if (error) redirect(`/internal/accounting-command-centre?queue=cancelled_or_superseded&error=${encodeURIComponent(error.message)}`);
    rows = ((data ?? []) as FreezeResult[]);
    await revalidateFrozenSnapshots(supabase, frozenSnapshotIds(rows));
  } else if (lane === "supplier_goods_ap") {
    const { data, error } = await (supabase as any).rpc("internal_freeze_supplier_goods_ap_sage_batch_v1", {
      p_supplier_invoice_ids: [sourceId],
      p_notes: "Accounting command centre re-freeze source from cancelled/superseded batch history",
    });
    if (error) redirect(`/internal/accounting-command-centre?queue=cancelled_or_superseded&error=${encodeURIComponent(error.message)}`);
    rows = ((data ?? []) as FreezeResult[]);
  } else if (lane === "shipper_ap") {
    const { data, error } = await (supabase as any).rpc("internal_freeze_shipper_ap_sage_batch_v1", {
      p_shipping_document_ids: [sourceId],
      p_notes: "Accounting command centre re-freeze source from cancelled/superseded batch history",
    });
    if (error) redirect(`/internal/accounting-command-centre?queue=cancelled_or_superseded&error=${encodeURIComponent(error.message)}`);
    rows = ((data ?? []) as FreezeResult[]);
  }

  const frozenCount = rows.filter((row) => row.freeze_status === "frozen" && row.snapshot_id).length;
  const blocker = rows.find((row) => row.freeze_status !== "frozen")?.blocker;

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  if (frozenCount === 0) {
    redirect(`/internal/accounting-command-centre?queue=cancelled_or_superseded&lane=${encodeURIComponent(lane)}&error=${encodeURIComponent(blocker || "Source was not re-frozen")}`);
  }

  redirect(`/internal/accounting-command-centre?queue=frozen_ready_to_post&lane=${encodeURIComponent(lane)}&success=${encodeURIComponent(`Re-frozen ${lane.replaceAll("_", " ")} source. Create a new posting batch from the fresh frozen row.`)}`);
}
