"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PROGRESSION_BASELINE_EXCEEDED_ERROR = "Cannot progress selected lines because they exceed the original order baseline. Move excess or mismatched items into the exception path.";
const MANUAL_ADD_BASELINE_EXCEEDED_ERROR = "Cannot add manual line because it exceeds the original order baseline.";
const MANUAL_EDIT_BASELINE_EXCEEDED_ERROR = "Cannot update line because it exceeds the original order baseline.";
const CURRENCY_TOLERANCE_GBP = 0.01;
const RETIRED_INVOICE_REVIEW_STATUSES = new Set(["rejected_resubmit_required", "superseded", "duplicate_blocked"]);

function isProgressedFlag(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function invoiceReviewStatusForLine(line: unknown) {
  const nested = (line as { supplier_invoices?: unknown }).supplier_invoices;
  const invoice = Array.isArray(nested) ? nested[0] : nested;
  if (!invoice || typeof invoice !== "object") return null;
  const status = (invoice as { review_status?: unknown }).review_status;
  return status === null || status === undefined ? null : String(status);
}

function isLiveInvoiceLine(line: unknown) {
  const status = invoiceReviewStatusForLine(line);
  return !status || !RETIRED_INVOICE_REVIEW_STATUSES.has(status);
}

type ProgressionLine = {
  id: string;
  qty: number | null;
  amount_inc_vat_gbp: number | null;
  qty_confirmed: number | null;
  amount_confirmed: number | null;
  eligible_for_invoice_yn: string | null;
};

function lineProgressionValues(line: ProgressionLine) {
  const qty = Number(line.qty_confirmed ?? line.qty ?? 0);
  const amount = Number(line.amount_confirmed ?? line.amount_inc_vat_gbp ?? 0);
  return {
    qty: Number.isFinite(qty) ? qty : 0,
    amount: Number.isFinite(amount) ? amount : 0,
  };
}

async function enforceProgressionWithinBaseline(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  orderId: string;
  lineIds: string[];
}) {
  const { supabase, orderId, lineIds } = params;

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, total_qty_declared, order_total_gbp_declared")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    return { ok: false as const, error: orderError?.message ?? "Order not found." };
  }

  const { data: allLines, error: linesError } = await supabase
    .from("supplier_invoice_lines")
    .select("id, qty, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn, supplier_invoices!inner(order_id, review_status)")
    .eq("supplier_invoices.order_id", orderId);

  if (linesError) {
    return { ok: false as const, error: linesError.message };
  }

  const lines = ((allLines ?? []) as ProgressionLine[]).filter(isLiveInvoiceLine);
  const lineById = new Map(lines.map((line) => [line.id, line]));
  const selectedLines = lineIds.map((lineId) => lineById.get(lineId)).filter((line): line is ProgressionLine => Boolean(line));

  if (selectedLines.length !== lineIds.length) {
    return { ok: false as const, error: "One or more selected lines could not be found for this active invoice." };
  }

  const selectedLineIds = new Set(selectedLines.map((line) => line.id));

  const currentProgressed = lines
    .filter((line) => isProgressedFlag(line.eligible_for_invoice_yn) && !selectedLineIds.has(line.id))
    .reduce(
      (totals, line) => {
        const values = lineProgressionValues(line);
        return {
          qty: totals.qty + values.qty,
          amount: totals.amount + values.amount,
        };
      },
      { qty: 0, amount: 0 }
    );

  const selectedUnresolvedTotals = selectedLines
    .filter((line) => !isProgressedFlag(line.eligible_for_invoice_yn))
    .reduce(
      (totals, line) => {
        const values = lineProgressionValues(line);
        return {
          qty: totals.qty + values.qty,
          amount: totals.amount + values.amount,
        };
      },
      { qty: 0, amount: 0 }
    );

  const baselineQty = Number(order.total_qty_declared ?? 0);
  const baselineAmount = Number(order.order_total_gbp_declared ?? 0);

  const exceedsQty = currentProgressed.qty + selectedUnresolvedTotals.qty > baselineQty;
  const exceedsAmount = currentProgressed.amount + selectedUnresolvedTotals.amount > baselineAmount + CURRENCY_TOLERANCE_GBP;

  if (exceedsQty || exceedsAmount) {
    return { ok: false as const, error: PROGRESSION_BASELINE_EXCEEDED_ERROR };
  }

  return { ok: true as const };
}

async function enforceManualEditWithinBaseline(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  orderId: string;
  lineId: string;
  nextQty: number;
  nextAmount: number;
}) {
  const { supabase, orderId, lineId, nextQty, nextAmount } = params;

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, total_qty_declared, order_total_gbp_declared")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    return { ok: false as const, error: orderError?.message ?? "Order not found." };
  }

  const { data: allLines, error: linesError } = await supabase
    .from("supplier_invoice_lines")
    .select("id, qty, amount_inc_vat_gbp, supplier_invoices!inner(order_id, review_status)")
    .eq("supplier_invoices.order_id", orderId);

  if (linesError) {
    return { ok: false as const, error: linesError.message };
  }

  const currentTotalsExcludingLine = (allLines ?? [])
    .filter((line) => line.id !== lineId && isLiveInvoiceLine(line))
    .reduce(
      (totals, line) => ({
        qty: totals.qty + Number(line.qty ?? 0),
        amount: totals.amount + Number(line.amount_inc_vat_gbp ?? 0),
      }),
      { qty: 0, amount: 0 }
    );

  const totalQtyAfterEdit = currentTotalsExcludingLine.qty + nextQty;
  const totalAmountAfterEdit = currentTotalsExcludingLine.amount + nextAmount;
  const baselineQty = Number(order.total_qty_declared ?? 0);
  const baselineAmount = Number(order.order_total_gbp_declared ?? 0);

  const exceedsQty = totalQtyAfterEdit > baselineQty;
  const exceedsAmount = totalAmountAfterEdit > baselineAmount + CURRENCY_TOLERANCE_GBP;

  if (exceedsQty || exceedsAmount) {
    return { ok: false as const, error: MANUAL_EDIT_BASELINE_EXCEEDED_ERROR };
  }

  return { ok: true as const };
}

async function enforceLinesNotLinkedToOpenException(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  lineIds: string[];
}) {
  const { supabase, lineIds } = params;
  if (lineIds.length === 0) {
    return { ok: true as const };
  }

  const { data: openLinks, error } = await supabase
    .from("dispute_lines")
    .select("supplier_invoice_line_id")
    .in("supplier_invoice_line_id", lineIds)
    .is("resolved_at", null);

  if (error) {
    return { ok: false as const, error: error.message };
  }

  if ((openLinks ?? []).length > 0) {
    return { ok: false as const, error: "Exception-linked lines cannot be progressed." };
  }

  return { ok: true as const };
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readNumber(formData: FormData, key: string) {
  const value = Number(readString(formData, key));
  return Number.isFinite(value) ? value : null;
}

function readInteger(formData: FormData, key: string) {
  const value = readNumber(formData, key);
  return value !== null && Number.isInteger(value) ? value : null;
}

function readOptionalString(formData: FormData, key: string) {
  const value = readString(formData, key);
  return value.length > 0 ? value : null;
}

function readStringArray(formData: FormData, key: string) {
  return formData.getAll(key).filter((value): value is string => typeof value === "string" && value.trim().length > 0);
}

function redirectWithResult(orderId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/reconciliation/${orderId}?${query.toString()}`);
}

async function requireActiveOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { supabase, ok: false as const, error: "Please sign in again." };
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    return { supabase, ok: false as const, error: "Active operator account not found." };
  }

  return { supabase, ok: true as const, operatorId: operator.id };
}

export async function updateSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");
  const qty = readInteger(formData, "qty");
  const submittedAmount = readNumber(formData, "amount_inc_vat_gbp");
  const description = readString(formData, "description");
  const size = readOptionalString(formData, "size");
  const retailerSku = readOptionalString(formData, "retailer_sku");

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  if (!description) {
    redirectWithResult(orderId, { error: "Description cannot be blank." });
  }

  if (qty === null || qty < 0) {
    redirectWithResult(orderId, { error: "Quantity must be a valid non-negative integer." });
  }

  if (submittedAmount === null || submittedAmount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { data: existingLine, error: existingLineError } = await guard.supabase
    .from("supplier_invoice_lines")
    .select("id, line_source, description, amount_inc_vat_gbp, supplier_invoices!inner(order_id, review_status)")
    .eq("id", lineId)
    .eq("supplier_invoices.order_id", orderId)
    .maybeSingle();

  if (existingLineError || !existingLine) {
    redirectWithResult(orderId, { error: existingLineError?.message ?? "Invoice line not found for this order." });
  }

  if (!isLiveInvoiceLine(existingLine)) {
    redirectWithResult(orderId, { error: "Rejected or superseded invoice lines cannot be edited." });
  }

  const isOcrLine = String(existingLine.line_source ?? "").trim().toLowerCase() === "ocr_extracted";
  const effectiveAmount = isOcrLine ? Number(existingLine.amount_inc_vat_gbp ?? 0) : submittedAmount;
  const effectiveDescription = isOcrLine ? String(existingLine.description ?? description) : description;

  const exceptionGuard = await enforceLinesNotLinkedToOpenException({ supabase: guard.supabase, lineIds: [lineId] });
  if (!exceptionGuard.ok) {
    redirectWithResult(orderId, { error: "Exception-linked lines cannot be edited." });
  }

  const baselineGuard = await enforceManualEditWithinBaseline({
    supabase: guard.supabase,
    orderId,
    lineId,
    nextQty: qty,
    nextAmount: effectiveAmount,
  });
  if (!baselineGuard.ok) {
    redirectWithResult(orderId, { error: baselineGuard.error });
  }

  const { error } = await guard.supabase.rpc("operator_update_supplier_invoice_line_fields", {
    p_order_id: orderId,
    p_line_id: lineId,
    p_description: effectiveDescription,
    p_qty: qty,
    p_amount_inc_vat_gbp: effectiveAmount,
    p_size: size,
    p_retailer_sku: retailerSku,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: isOcrLine ? "OCR line updated. OCR amount was preserved." : "Line updated." });
}

export async function addManualSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id");
  const qty = readInteger(formData, "qty");
  const amount = readNumber(formData, "amount_inc_vat_gbp");
  const description = readString(formData, "description");
  const size = readOptionalString(formData, "size");
  const retailerSku = readOptionalString(formData, "retailer_sku");

  if (!orderId || !supplierInvoiceId) {
    redirect("/importer");
  }

  if (!description) {
    redirectWithResult(orderId, { error: "Description cannot be blank." });
  }

  if (qty === null || qty < 0) {
    redirectWithResult(orderId, { error: "Quantity must be a valid non-negative integer." });
  }

  if (amount === null || amount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { data: targetInvoice, error: targetInvoiceError } = await guard.supabase
    .from("supplier_invoices")
    .select("id, review_status")
    .eq("id", supplierInvoiceId)
    .eq("order_id", orderId)
    .maybeSingle();

  if (targetInvoiceError || !targetInvoice) {
    redirectWithResult(orderId, { error: targetInvoiceError?.message ?? "Supplier invoice not found for this order." });
  }

  if (RETIRED_INVOICE_REVIEW_STATUSES.has(String(targetInvoice.review_status ?? ""))) {
    redirectWithResult(orderId, { error: "Cannot add lines to a rejected, superseded, or duplicate-blocked invoice. Use the active corrected invoice." });
  }

  const { data: order, error: orderError } = await guard.supabase
    .from("orders")
    .select("id, total_qty_declared, order_total_gbp_declared")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    redirectWithResult(orderId, { error: "Order not found." });
  }

  const { data: allLines, error: linesError } = await guard.supabase
    .from("supplier_invoice_lines")
    .select("qty, amount_inc_vat_gbp, supplier_invoices!inner(order_id, review_status)")
    .eq("supplier_invoices.order_id", orderId);

  if (linesError) {
    redirectWithResult(orderId, { error: linesError.message });
  }

  const liveLines = (allLines ?? []).filter(isLiveInvoiceLine);
  const currentQty = liveLines.reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const currentAmount = liveLines.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
  const baselineQty = Number(order.total_qty_declared ?? 0);
  const baselineAmount = Number(order.order_total_gbp_declared ?? 0);

  const exceedsQty = currentQty + qty > baselineQty;
  const exceedsAmount = currentAmount + amount > baselineAmount + CURRENCY_TOLERANCE_GBP;
  if (exceedsQty || exceedsAmount) {
    redirectWithResult(orderId, { error: MANUAL_ADD_BASELINE_EXCEEDED_ERROR });
  }

  const { error } = await guard.supabase.rpc("operator_add_manual_supplier_invoice_line", {
    p_order_id: orderId,
    p_supplier_invoice_id: supplierInvoiceId,
    p_description: description,
    p_qty: qty,
    p_amount_inc_vat_gbp: amount,
    p_size: size,
    p_retailer_sku: retailerSku,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Manual line added." });
}

export async function deleteManualSupplierInvoiceLineAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const exceptionGuard = await enforceLinesNotLinkedToOpenException({ supabase: guard.supabase, lineIds: [lineId] });
  if (!exceptionGuard.ok) {
    redirectWithResult(orderId, { error: "Exception-linked lines cannot be deleted." });
  }

  const { error } = await guard.supabase.rpc("operator_delete_manual_supplier_invoice_line", {
    p_order_id: orderId,
    p_line_id: lineId,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Manual line deleted." });
}

export async function markSupplierInvoiceLineProgressedAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");

  if (!orderId || !lineId) {
    redirect("/importer");
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const progressionGuard = await enforceProgressionWithinBaseline({ supabase: guard.supabase, orderId, lineIds: [lineId] });
  if (!progressionGuard.ok) {
    redirectWithResult(orderId, { error: progressionGuard.error });
  }

  const exceptionGuard = await enforceLinesNotLinkedToOpenException({ supabase: guard.supabase, lineIds: [lineId] });
  if (!exceptionGuard.ok) {
    redirectWithResult(orderId, { error: exceptionGuard.error });
  }

  const { error } = await guard.supabase.rpc("operator_mark_supplier_invoice_line_progressed", {
    p_order_id: orderId,
    p_line_id: lineId,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Line marked progressed." });
}

export async function bulkMarkSupplierInvoiceLinesProgressedAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineIds = readStringArray(formData, "line_ids");

  if (!orderId) {
    redirect("/importer");
  }

  if (lineIds.length === 0) {
    redirectWithResult(orderId, { error: "Select at least one line to progress." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const progressionGuard = await enforceProgressionWithinBaseline({ supabase: guard.supabase, orderId, lineIds });
  if (!progressionGuard.ok) {
    redirectWithResult(orderId, { error: progressionGuard.error });
  }

  const exceptionGuard = await enforceLinesNotLinkedToOpenException({ supabase: guard.supabase, lineIds });
  if (!exceptionGuard.ok) {
    redirectWithResult(orderId, { error: exceptionGuard.error });
  }

  const { data, error } = await guard.supabase.rpc("operator_bulk_mark_supplier_invoice_lines_progressed", {
    p_order_id: orderId,
    p_line_ids: lineIds,
  });

  if (error) {
    redirectWithResult(orderId, { error: error.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: `${Number(data ?? lineIds.length)} line(s) marked progressed.` });
}

export async function createExceptionCaseAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const remedy = readString(formData, "remedy");
  const lineIds = [...new Set(readStringArray(formData, "exception_line_ids"))];

  if (!orderId) {
    redirect("/importer");
  }

  if (lineIds.length === 0) {
    redirectWithResult(orderId, { error: "Select at least one unresolved line to create an exception case." });
  }

  if (remedy !== "refund" && remedy !== "replacement") {
    redirectWithResult(orderId, { error: "Select a remedy intent (refund or replacement)." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { data: order, error: orderError } = await guard.supabase
    .from("orders")
    .select("id, importer_id, sop_version")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    redirectWithResult(orderId, { error: "Order not found." });
  }

  const { data: importerAccess, error: importerAccessError } = await guard.supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", guard.operatorId)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (importerAccessError || !importerAccess) {
    redirectWithResult(orderId, { error: "You are not authorised to create exception cases for this order." });
  }

  const { data: selectedLines, error: selectedLinesError } = await guard.supabase
    .from("supplier_invoice_lines")
    .select(
      "id, qty, amount_inc_vat_gbp, eligible_for_invoice_yn, supplier_invoices!inner(order_id, review_status)"
    )
    .in("id", lineIds)
    .eq("supplier_invoices.order_id", orderId);

  if (selectedLinesError) {
    redirectWithResult(orderId, { error: selectedLinesError.message });
  }

  if ((selectedLines ?? []).length !== lineIds.length) {
    redirectWithResult(orderId, { error: "One or more selected lines do not belong to this order." });
  }

  if ((selectedLines ?? []).some((line) => !isLiveInvoiceLine(line))) {
    redirectWithResult(orderId, { error: "Rejected or superseded invoice lines cannot be added to an exception case." });
  }

  const progressedLine = selectedLines?.find((line) => isProgressedFlag(line.eligible_for_invoice_yn));
  if (progressedLine) {
    redirectWithResult(orderId, { error: "Line is already progressed and cannot be added to an exception case." });
  }

  const { data: existingOpenLinks, error: openLinksError } = await guard.supabase
    .from("dispute_lines")
    .select("id, supplier_invoice_line_id")
    .in("supplier_invoice_line_id", lineIds)
    .is("resolved_at", null);

  if (openLinksError) {
    redirectWithResult(orderId, { error: openLinksError.message });
  }

  if ((existingOpenLinks ?? []).length > 0) {
    redirectWithResult(orderId, { error: "One or more selected lines already has an exception case." });
  }

  const lineTotals = (selectedLines ?? []).reduce(
    (totals, line) => ({
      qty: totals.qty + Number(line.qty ?? 0),
      amount: totals.amount + Number(line.amount_inc_vat_gbp ?? 0),
    }),
    { qty: 0, amount: 0 }
  );

  const conversationStatus = remedy === "refund" ? "refund_pending_approval" : "remedy_selected";

  const { data: existingDispute, error: existingDisputeError } = await guard.supabase
    .from("disputes")
    .select("id, amount_impact_gbp, replacement_child_order_id")
    .eq("order_id", orderId)
    .eq("desired_outcome", remedy)
    .eq("status", "raised")
    .is("resolved_at", null)
    .order("raised_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (existingDisputeError) {
    redirectWithResult(orderId, { error: existingDisputeError.message });
  }

  let disputeId = existingDispute?.id ?? null;
  if (!disputeId) {
    const { data: createdDispute, error: createDisputeError } = await guard.supabase
      .from("disputes")
      .insert({
        order_id: orderId,
        raised_by_operator_id: guard.operatorId,
        issue_type: "missing",
        desired_outcome: remedy,
        liable_party: "unknown",
        stage_detected: "at_reconciliation",
        amount_impact_gbp: lineTotals.amount,
        status: "raised",
        sop_version: order.sop_version,
      })
      .select("id")
      .single();
    if (createDisputeError) {
      redirectWithResult(orderId, { error: createDisputeError.message });
    }
    disputeId = createdDispute.id;
  } else {
    const currentDisputeAmount = Number(existingDispute?.amount_impact_gbp ?? 0);
    const updatedAmount = currentDisputeAmount + lineTotals.amount;
    const { error: updateAmountError } = await guard.supabase
      .from("disputes")
      .update({ amount_impact_gbp: updatedAmount })
      .eq("id", disputeId);
    if (updateAmountError) {
      redirectWithResult(orderId, { error: updateAmountError.message });
    }
  }

  const disputeLineRows = (selectedLines ?? []).map((line) => ({
    dispute_id: disputeId,
    supplier_invoice_line_id: line.id,
    qty_impact: Number(line.qty ?? 0),
    amount_impact_gbp: Number(line.amount_inc_vat_gbp ?? 0),
    line_status: "affected",
    intended_remedy: remedy,
    conversation_status: conversationStatus,
  }));

  const { error: createLinesError } = await guard.supabase.from("dispute_lines").insert(disputeLineRows);
  if (createLinesError) {
    redirectWithResult(orderId, { error: createLinesError.message });
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: `Exception case created for ${lineIds.length} line(s).` });
}

export async function rescindExceptionCaseAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const disputeId = readString(formData, "dispute_id");

  if (!orderId || !disputeId) {
    redirect("/importer");
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { data: order, error: orderError } = await guard.supabase
    .from("orders")
    .select("id, importer_id")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    redirectWithResult(orderId, { error: "Order not found." });
  }

  const { data: importerAccess, error: importerAccessError } = await guard.supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", guard.operatorId)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (importerAccessError || !importerAccess) {
    redirectWithResult(orderId, { error: "You are not authorised to rescind exception cases for this order." });
  }

  const { data: dispute, error: disputeError } = await guard.supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, refund_approved_at, replacement_child_order_id, customer_credit_note_sales_invoice_id")
    .eq("id", disputeId)
    .eq("order_id", orderId)
    .is("resolved_at", null)
    .maybeSingle();

  if (disputeError || !dispute) {
    redirectWithResult(orderId, { error: "Open exception case not found for this order." });
  }

  const { count: messageCount, error: messageCountError } = await guard.supabase
    .from("dispute_messages")
    .select("id", { count: "exact", head: true })
    .eq("dispute_id", disputeId);

  if (messageCountError) {
    redirectWithResult(orderId, { error: messageCountError.message });
  }

  const hasMessages = Number(messageCount ?? 0) > 0;

  if (dispute.desired_outcome === "refund") {
    if (dispute.refund_approved_at || hasMessages || dispute.customer_credit_note_sales_invoice_id) {
      redirectWithResult(orderId, { error: "Cannot rescind refund exception after approval or downstream activity." });
    }
  } else {
    if (dispute.replacement_child_order_id) {
      redirectWithResult(orderId, { error: "Cannot rescind replacement exception because a replacement child order already exists." });
    }

    if (hasMessages || dispute.customer_credit_note_sales_invoice_id) {
      redirectWithResult(orderId, { error: "Cannot rescind replacement exception after downstream activity has started." });
    }
  }

  const { error: deleteDisputeLinesError } = await guard.supabase
    .from("dispute_lines")
    .delete()
    .eq("dispute_id", disputeId)
    .is("resolved_at", null);
  if (deleteDisputeLinesError) {
    redirectWithResult(orderId, { error: deleteDisputeLinesError.message });
  }

  const { data: remainingLines, error: remainingLinesError } = await guard.supabase
    .from("dispute_lines")
    .select("id, amount_impact_gbp")
    .eq("dispute_id", disputeId);
  if (remainingLinesError) {
    redirectWithResult(orderId, { error: remainingLinesError.message });
  }

  if ((remainingLines ?? []).length === 0) {
    const { error: deleteDisputeError } = await guard.supabase.from("disputes").delete().eq("id", disputeId);
    if (deleteDisputeError) {
      redirectWithResult(orderId, { error: deleteDisputeError.message });
    }
  } else {
    const updatedAmount = (remainingLines ?? []).reduce((sum, line) => sum + Number(line.amount_impact_gbp ?? 0), 0);
    const { error: updateDisputeError } = await guard.supabase
      .from("disputes")
      .update({ amount_impact_gbp: updatedAmount })
      .eq("id", disputeId);
    if (updateDisputeError) {
      redirectWithResult(orderId, { error: updateDisputeError.message });
    }
  }

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Exception case rescinded." });
}
