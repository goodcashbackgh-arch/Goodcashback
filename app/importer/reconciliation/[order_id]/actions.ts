"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PROGRESSION_BASELINE_EXCEEDED_ERROR = "Cannot progress selected lines because they exceed the original order baseline. Move excess or mismatched items into the exception path.";
const CURRENCY_TOLERANCE_GBP = 0.01;

function isProgressedFlag(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
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
    .select("id, qty, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn, supplier_invoices!inner(order_id)")
    .eq("supplier_invoices.order_id", orderId);

  if (linesError) {
    return { ok: false as const, error: linesError.message };
  }

  const lines = (allLines ?? []) as ProgressionLine[];
  const lineById = new Map(lines.map((line) => [line.id, line]));
  const selectedLines = lineIds.map((lineId) => lineById.get(lineId)).filter((line): line is ProgressionLine => Boolean(line));

  if (selectedLines.length !== lineIds.length) {
    return { ok: false as const, error: "One or more selected lines could not be found for this order." };
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
  const amount = readNumber(formData, "amount_inc_vat_gbp");
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

  if (amount === null || amount < 0) {
    redirectWithResult(orderId, { error: "Amount must be a valid non-negative number." });
  }

  const guard = await requireActiveOperator();
  if (!guard.ok) {
    redirectWithResult(orderId, { error: guard.error });
  }

  const { error } = await guard.supabase.rpc("operator_update_supplier_invoice_line_fields", {
    p_order_id: orderId,
    p_line_id: lineId,
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
  redirectWithResult(orderId, { success: "Line updated." });
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
      "id, qty, amount_inc_vat_gbp, eligible_for_invoice_yn, supplier_invoices!inner(order_id)"
    )
    .in("id", lineIds)
    .eq("supplier_invoices.order_id", orderId);

  if (selectedLinesError) {
    redirectWithResult(orderId, { error: selectedLinesError.message });
  }

  if ((selectedLines ?? []).length !== lineIds.length) {
    redirectWithResult(orderId, { error: "One or more selected lines do not belong to this order." });
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
    .select("id, amount_impact_gbp")
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
