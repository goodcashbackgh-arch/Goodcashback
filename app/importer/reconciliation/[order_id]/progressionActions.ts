"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PROGRESSION_BASELINE_EXCEEDED_ERROR = "Cannot progress selected lines because they exceed the original order baseline. Move excess or mismatched items into the exception path.";
const CURRENCY_TOLERANCE_GBP = 0.01;
const RETIRED_INVOICE_REVIEW_STATUSES = new Set(["rejected_resubmit_required", "superseded", "duplicate_blocked"]);

type ProgressionLine = {
  id: string;
  supplier_invoice_id: string;
  description: string;
  qty: number | null;
  amount_inc_vat_gbp: number | null;
  qty_confirmed: number | null;
  amount_confirmed: number | null;
  eligible_for_invoice_yn: string | null;
};

type ProgressionResolution = {
  supplier_invoice_line_id: string;
  resolution_type: string;
  financial_type: string;
};

type OrderValueAdjustment = {
  supplier_invoice_id: string | null;
  adjustment_type: string;
  amount_gbp: number;
  approval_status: string | null;
};

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

function normalisedDescription(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function isDiscountDescription(value: string) {
  return /(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)/.test(normalisedDescription(value));
}

function isDeliveryDescription(value: string) {
  return /(^| )(delivery|shipping|postage|freight|carriage)( |$)/.test(normalisedDescription(value));
}

function unresolvedFinancialKind(line: ProgressionLine) {
  const amount = Number(line.amount_inc_vat_gbp ?? 0);
  if (amount < 0 && isDiscountDescription(line.description)) return "discount" as const;
  if (amount > 0 && isDeliveryDescription(line.description)) return "delivery" as const;
  return null;
}

function resolvedFinancialAmount(line: ProgressionLine, resolution: ProgressionResolution) {
  const amount = Number(line.amount_inc_vat_gbp ?? 0);
  if (resolution.financial_type === "discount") return -Math.abs(amount);
  if (["delivery", "fee"].includes(resolution.financial_type)) return Math.abs(amount);
  if (resolution.financial_type === "zero_value_delivery") return 0;
  return amount;
}

function provedUnresolvedFinancialOffset(params: {
  lines: ProgressionLine[];
  accountedLineIds: Set<string>;
  resolvedLineIds: Set<string>;
  disputeLineIds: Set<string>;
  selectedInvoiceIds: Set<string>;
  adjustments: OrderValueAdjustment[];
}) {
  const { lines, accountedLineIds, resolvedLineIds, disputeLineIds, selectedInvoiceIds, adjustments } = params;
  let offset = 0;

  for (const supplierInvoiceId of selectedInvoiceIds) {
    const invoiceLines = lines.filter(
      (line) =>
        line.supplier_invoice_id === supplierInvoiceId &&
        !accountedLineIds.has(line.id) &&
        !resolvedLineIds.has(line.id) &&
        !disputeLineIds.has(line.id)
    );
    const invoiceAdjustments = adjustments.filter(
      (adjustment) => adjustment.supplier_invoice_id === supplierInvoiceId && adjustment.approval_status !== "rejected"
    );

    for (const kind of ["discount", "delivery"] as const) {
      const extractedAmount = invoiceLines
        .filter((line) => unresolvedFinancialKind(line) === kind)
        .reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
      const adjustmentAmount = invoiceAdjustments
        .filter((adjustment) => adjustment.adjustment_type === `retailer_${kind}`)
        .reduce((sum, adjustment) => sum + Number(adjustment.amount_gbp ?? 0), 0);

      if (
        extractedAmount !== 0 &&
        Math.abs(Math.abs(extractedAmount) - Math.abs(adjustmentAmount)) <= CURRENCY_TOLERANCE_GBP
      ) {
        offset += extractedAmount;
      }
    }
  }

  return offset;
}

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
    .select("id, supplier_invoice_id, description, qty, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn, supplier_invoices!inner(order_id, review_status)")
    .eq("supplier_invoices.order_id", orderId);

  if (linesError) return { ok: false as const, error: linesError.message };

  const lines = ((allLines ?? []) as ProgressionLine[]).filter(isLiveInvoiceLine);
  const lineById = new Map(lines.map((line) => [line.id, line]));
  const selectedLines = lineIds.map((lineId) => lineById.get(lineId)).filter((line): line is ProgressionLine => Boolean(line));

  if (selectedLines.length !== lineIds.length) {
    return { ok: false as const, error: "One or more selected lines could not be found for this active invoice." };
  }

  const liveLineIds = lines.map((line) => line.id);
  const invoiceIds = [...new Set(lines.map((line) => line.supplier_invoice_id))];
  const [
    { data: resolutionRows, error: resolutionsError },
    { data: disputeRows, error: disputesError },
    { data: adjustmentRows, error: adjustmentsError },
  ] = await Promise.all([
    liveLineIds.length
      ? supabase
          .from("supplier_invoice_line_resolutions")
          .select("supplier_invoice_line_id, resolution_type, financial_type")
          .in("supplier_invoice_line_id", liveLineIds)
          .eq("active", true)
          .eq("resolution_type", "non_physical_financial")
      : Promise.resolve({ data: [] as ProgressionResolution[], error: null }),
    liveLineIds.length
      ? supabase
          .from("dispute_lines")
          .select("supplier_invoice_line_id")
          .in("supplier_invoice_line_id", liveLineIds)
          .is("resolved_at", null)
      : Promise.resolve({ data: [] as { supplier_invoice_line_id: string }[], error: null }),
    invoiceIds.length
      ? supabase
          .from("order_value_adjustments")
          .select("supplier_invoice_id, adjustment_type, amount_gbp, approval_status")
          .eq("order_id", orderId)
          .in("supplier_invoice_id", invoiceIds)
      : Promise.resolve({ data: [] as OrderValueAdjustment[], error: null }),
  ]);

  if (resolutionsError || disputesError || adjustmentsError) {
    return {
      ok: false as const,
      error:
        resolutionsError?.message ??
        disputesError?.message ??
        adjustmentsError?.message ??
        "Unable to verify the order baseline.",
    };
  }

  const resolutions = new Map(
    ((resolutionRows ?? []) as ProgressionResolution[]).map((resolution) => [resolution.supplier_invoice_line_id, resolution])
  );
  const disputeLineIds = new Set((disputeRows ?? []).map((row) => row.supplier_invoice_line_id));
  const accountedLineIds = new Set(
    lines
      .filter((line) => isProgressedFlag(line.eligible_for_invoice_yn) || resolutions.has(line.id))
      .map((line) => line.id)
  );

  if (selectedLines.some((line) => unresolvedFinancialKind(line) !== null || resolutions.has(line.id))) {
    return { ok: false as const, error: "Non-physical financial lines cannot be progressed as physical goods." };
  }

  const alreadyAccounted = lines
    .filter((line) => accountedLineIds.has(line.id))
    .reduce(
      (totals, line) => {
        const values = lineProgressionValues(line);
        const resolution = resolutions.get(line.id);
        return {
          qty: totals.qty + (resolution ? 0 : values.qty),
          amount: totals.amount + (resolution ? resolvedFinancialAmount(line, resolution) : values.amount),
        };
      },
      { qty: 0, amount: 0 }
    );

  const selectedUnresolvedTotals = selectedLines
    .filter((line) => !accountedLineIds.has(line.id))
    .reduce(
      (totals, line) => {
        const values = lineProgressionValues(line);
        return { qty: totals.qty + values.qty, amount: totals.amount + values.amount };
      },
      { qty: 0, amount: 0 }
    );

  const unresolvedFinancialOffset = provedUnresolvedFinancialOffset({
    lines,
    accountedLineIds,
    resolvedLineIds: new Set(resolutions.keys()),
    disputeLineIds,
    selectedInvoiceIds: new Set(selectedLines.map((line) => line.supplier_invoice_id)),
    adjustments: (adjustmentRows ?? []) as OrderValueAdjustment[],
  });

  const baselineQty = Number(order.total_qty_declared ?? 0);
  const baselineAmount = Number(order.order_total_gbp_declared ?? 0);
  const exceedsQty = alreadyAccounted.qty + selectedUnresolvedTotals.qty > baselineQty;
  const exceedsAmount =
    alreadyAccounted.amount + selectedUnresolvedTotals.amount + unresolvedFinancialOffset >
    baselineAmount + CURRENCY_TOLERANCE_GBP;

  if (exceedsQty || exceedsAmount) {
    return { ok: false as const, error: PROGRESSION_BASELINE_EXCEEDED_ERROR };
  }

  return { ok: true as const };
}

async function enforceLinesNotLinkedToOpenException(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  lineIds: string[];
}) {
  const { supabase, lineIds } = params;
  if (lineIds.length === 0) return { ok: true as const };

  const { data: openLinks, error } = await supabase
    .from("dispute_lines")
    .select("supplier_invoice_line_id")
    .in("supplier_invoice_line_id", lineIds)
    .is("resolved_at", null);

  if (error) return { ok: false as const, error: error.message };
  if ((openLinks ?? []).length > 0) return { ok: false as const, error: "Exception-linked lines cannot be progressed." };
  return { ok: true as const };
}

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
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
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { supabase, ok: false as const, error: "Please sign in again." };

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) return { supabase, ok: false as const, error: "Active operator account not found." };
  return { supabase, ok: true as const };
}

export async function markSupplierInvoiceLineProgressedAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineId = readString(formData, "line_id");
  if (!orderId || !lineId) redirect("/importer");

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(orderId, { error: guard.error });

  const progressionGuard = await enforceProgressionWithinBaseline({ supabase: guard.supabase, orderId, lineIds: [lineId] });
  if (!progressionGuard.ok) redirectWithResult(orderId, { error: progressionGuard.error });

  const exceptionGuard = await enforceLinesNotLinkedToOpenException({ supabase: guard.supabase, lineIds: [lineId] });
  if (!exceptionGuard.ok) redirectWithResult(orderId, { error: exceptionGuard.error });

  const { error } = await guard.supabase.rpc("operator_mark_supplier_invoice_line_progressed", {
    p_order_id: orderId,
    p_line_id: lineId,
  });
  if (error) redirectWithResult(orderId, { error: error.message });

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: "Line marked progressed." });
}

export async function bulkMarkSupplierInvoiceLinesProgressedAction(formData: FormData) {
  const orderId = readString(formData, "order_id");
  const lineIds = readStringArray(formData, "line_ids");
  if (!orderId) redirect("/importer");
  if (lineIds.length === 0) redirectWithResult(orderId, { error: "Select at least one line to progress." });

  const guard = await requireActiveOperator();
  if (!guard.ok) redirectWithResult(orderId, { error: guard.error });

  const progressionGuard = await enforceProgressionWithinBaseline({ supabase: guard.supabase, orderId, lineIds });
  if (!progressionGuard.ok) redirectWithResult(orderId, { error: progressionGuard.error });

  const exceptionGuard = await enforceLinesNotLinkedToOpenException({ supabase: guard.supabase, lineIds });
  if (!exceptionGuard.ok) redirectWithResult(orderId, { error: exceptionGuard.error });

  const { data, error } = await guard.supabase.rpc("operator_bulk_mark_supplier_invoice_lines_progressed", {
    p_order_id: orderId,
    p_line_ids: lineIds,
  });
  if (error) redirectWithResult(orderId, { error: error.message });

  revalidatePath(`/importer/reconciliation/${orderId}`);
  redirectWithResult(orderId, { success: `${Number(data ?? lineIds.length)} line(s) marked progressed.` });
}
