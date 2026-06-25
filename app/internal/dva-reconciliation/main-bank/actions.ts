"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readStringList(formData: FormData, key: string) {
  return formData
    .getAll(key)
    .map((value) => (typeof value === "string" ? value.trim() : ""))
    .filter(Boolean);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function round2(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/dva-reconciliation/main-bank?${query.toString()}`);
}

async function confirmedResidualForLine(supabase: Awaited<ReturnType<typeof createClient>>, statementLineId: string) {
  const { data } = await supabase
    .from("dva_statement_line_allocations")
    .select("allocated_gbp_amount")
    .eq("dva_statement_line_id", statementLineId)
    .eq("allocation_status", "confirmed")
    .in("allocation_type", ["fx_card_difference", "bank_fee", "unmatched_hold"]);

  return round2(((data ?? []) as Row[]).reduce((sum, row) => sum + num(row.allocated_gbp_amount), 0));
}

function safeLineRemaining(row: Row, confirmedResidualGbp: number) {
  const readModelRemaining = round2(num(row.remaining_gbp));
  const legacyRemainingAfterResidual = round2(Math.max(num(row.amount_gbp) - num(row.allocated_gbp) - confirmedResidualGbp, 0));
  return Math.min(readModelRemaining, legacyRemainingAfterResidual);
}

export async function allocateMainBankLineToShipperApAction(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ error: "Please sign in again before allocating the main bank line." });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const shippingDocumentIds = Array.from(new Set(readStringList(formData, "shipping_document_id")));
  const amountRaw = readString(formData, "allocated_gbp_amount");
  const notes = readString(formData, "notes") || null;
  const amount = amountRaw ? Number(amountRaw) : null;

  if (!statementLineId || shippingDocumentIds.length === 0) {
    redirectWithResult({ error: "Select one main-bank OUT line and at least one posted shipper AP invoice." });
  }

  if (amountRaw && (!Number.isFinite(amount) || Number(amount) <= 0)) {
    redirectWithResult({ error: "Allocation amount must be greater than zero." });
  }

  if (shippingDocumentIds.length > 1 && amountRaw) {
    redirectWithResult({ error: "Amount override is only allowed when one shipper invoice is selected. For multiple invoices, each selected invoice is allocated at its remaining amount." });
  }

  const [{ data: lineRows, error: lineError }, { data: targetRows, error: targetError }] = await Promise.all([
    (supabase as any).rpc("internal_main_bank_shipper_statement_lines_v1", {
      p_status: "all",
      p_search: null,
      p_limit: 300,
      p_offset: 0,
    }),
    (supabase as any).rpc("internal_shipper_ap_posted_targets_for_main_bank_v1", {
      p_status: "all",
      p_search: null,
      p_limit: 300,
      p_offset: 0,
    }),
  ]);

  if (lineError) redirectWithResult({ error: lineError.message });
  if (targetError) redirectWithResult({ error: targetError.message });

  const selectedLine = ((lineRows ?? []) as Row[]).find((row) => text(row.statement_line_id) === statementLineId);
  if (!selectedLine) redirectWithResult({ error: "Selected main-bank statement line was not found." });

  const selectedTargets = ((targetRows ?? []) as Row[]).filter((row) => shippingDocumentIds.includes(text(row.shipping_document_id)));
  if (selectedTargets.length !== shippingDocumentIds.length) {
    redirectWithResult({ error: "One or more selected shipper AP invoices were not found or are no longer open." });
  }

  const uniqueShippers = new Set(selectedTargets.map((row) => text(row.shipper_id)).filter(Boolean));
  if (uniqueShippers.size > 1) {
    redirectWithResult({ error: "One bank payment can only be matched to invoices for one shipper/Sage contact. Split different shippers into separate bank lines or separate allocations." });
  }

  const residualGbp = await confirmedResidualForLine(supabase, statementLineId);
  const lineRemaining = safeLineRemaining(selectedLine, residualGbp);
  const targetTotal = round2(selectedTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));

  if (shippingDocumentIds.length > 1 && targetTotal > lineRemaining + 0.01) {
    redirectWithResult({ error: `Selected shipper invoices total £${targetTotal.toFixed(2)}, which exceeds the remaining bank line amount £${lineRemaining.toFixed(2)}.` });
  }

  let allocatedTotal = 0;
  let allocatedCount = 0;

  for (const target of selectedTargets) {
    const targetId = text(target.shipping_document_id);
    const allocationAmount = shippingDocumentIds.length === 1 && amountRaw ? amount : round2(num(target.remaining_gbp));

    if ((allocationAmount ?? 0) > lineRemaining - allocatedTotal + 0.01) {
      redirectWithResult({ error: `Selected shipper allocation exceeds remaining bank line amount £${lineRemaining.toFixed(2)} after FX/fee/loyalty consumption.` });
    }

    const { data, error } = await supabase.rpc("staff_allocate_main_bank_line_to_shipper_ap_v1", {
      p_dva_statement_line_id: statementLineId,
      p_shipping_document_id: targetId,
      p_allocated_gbp_amount: allocationAmount,
      p_notes: notes,
    });

    if (error) {
      redirectWithResult({ error: error.message });
    }

    const returnedAmount =
      typeof data === "object" && data !== null && "allocated_gbp_amount" in data
        ? num((data as { allocated_gbp_amount?: unknown }).allocated_gbp_amount)
        : allocationAmount ?? 0;

    allocatedTotal = round2(allocatedTotal + returnedAmount);
    allocatedCount += 1;
  }

  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/accounting-command-centre/cash-posting");

  redirectWithResult({
    success: `Allocated ${allocatedCount} shipper AP invoice(s), total £${allocatedTotal.toFixed(2)}.`,
  });
}

export async function matchMainBankLineToCompletionLoyaltyAction(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ error: "Please sign in again before reserving the loyalty funding line.", target: "completion_loyalty" });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const orderIds = Array.from(new Set(readStringList(formData, "order_id")));
  const amountRaw = readString(formData, "reward_amount_gbp");
  const amount = amountRaw ? Number(amountRaw) : null;
  const notes = readString(formData, "notes") || "Main-bank OUT reserved for completion loyalty reward.";

  if (!statementLineId || orderIds.length === 0) {
    redirectWithResult({ error: "Select one main-bank OUT line and at least one completion loyalty target.", target: "completion_loyalty" });
  }

  if (amountRaw && (!Number.isFinite(amount) || Number(amount) <= 0)) {
    redirectWithResult({ error: "Reward reserve amount must be greater than zero.", target: "completion_loyalty" });
  }

  if (orderIds.length > 1 && amountRaw) {
    redirectWithResult({ error: "Reward amount override is only allowed for one loyalty target. For multiple targets, each reward uses its own suggested reward amount.", target: "completion_loyalty" });
  }

  const [{ data: lineRows, error: lineError }, { data: targetRows, error: targetError }] = await Promise.all([
    (supabase as any).rpc("internal_main_bank_shipper_statement_lines_v1", {
      p_status: "all",
      p_search: null,
      p_limit: 300,
      p_offset: 0,
    }),
    (supabase as any).rpc("internal_main_bank_completion_loyalty_targets_v1", {
      p_search: null,
      p_limit: 300,
      p_offset: 0,
    }),
  ]);

  if (lineError) redirectWithResult({ error: lineError.message, target: "completion_loyalty" });
  if (targetError) redirectWithResult({ error: targetError.message, target: "completion_loyalty" });

  const selectedLine = ((lineRows ?? []) as Row[]).find((row) => text(row.statement_line_id) === statementLineId);
  if (!selectedLine) redirectWithResult({ error: "Selected main-bank OUT line was not found.", target: "completion_loyalty" });

  const selectedTargets = ((targetRows ?? []) as Row[]).filter((row) => orderIds.includes(text(row.order_id)));
  if (selectedTargets.length !== orderIds.length) {
    redirectWithResult({ error: "One or more selected loyalty targets were not found, already reserved, or no longer reward-ready.", target: "completion_loyalty" });
  }

  const uniqueImporters = new Set(selectedTargets.map((row) => text(row.importer_id)).filter(Boolean));
  if (uniqueImporters.size !== 1) {
    redirectWithResult({ error: "One main-bank OUT loyalty funding pot can only reserve rewards for one importer. Split different importers into separate OUT lines.", target: "completion_loyalty" });
  }

  const residualGbp = await confirmedResidualForLine(supabase, statementLineId);
  const lineRemaining = safeLineRemaining(selectedLine, residualGbp);
  const selectedTotal = round2(selectedTargets.reduce((sum, row) => sum + num(row.suggested_reward_gbp), 0));

  if (selectedTotal <= 0) {
    redirectWithResult({ error: "Selected loyalty reward total must be greater than zero.", target: "completion_loyalty" });
  }

  if (selectedTotal > lineRemaining + 0.01) {
    redirectWithResult({ error: `Selected loyalty rewards total £${selectedTotal.toFixed(2)}, which exceeds the remaining main-bank OUT amount £${lineRemaining.toFixed(2)}.`, target: "completion_loyalty" });
  }

  let reservedTotal = 0;
  let reservedCount = 0;
  const orderRefs: string[] = [];

  for (const target of selectedTargets) {
    const targetOrderId = text(target.order_id);
    const targetAmount = orderIds.length === 1 && amountRaw ? amount : round2(num(target.suggested_reward_gbp));
    const targetNotes = orderIds.length > 1
      ? `${notes}\nBulk main-bank OUT reservation group: ${orderIds.length} rewards selected.`
      : notes;

    if ((targetAmount ?? 0) > lineRemaining - reservedTotal + 0.01) {
      redirectWithResult({ error: `Selected loyalty rewards exceed remaining main-bank OUT amount £${lineRemaining.toFixed(2)} after earlier reservations in this group.`, target: "completion_loyalty" });
    }

    const { data, error } = await supabase.rpc("staff_stage_main_bank_line_to_completion_loyalty_v2", {
      p_dva_statement_line_id: statementLineId,
      p_order_id: targetOrderId,
      p_reward_amount_gbp: targetAmount,
      p_notes: targetNotes,
      p_activation_route: "dva_account_top_up",
      p_card_used_by: "staff",
    });

    if (error) redirectWithResult({ error: error.message, target: "completion_loyalty" });

    const returnedAmount =
      typeof data === "object" && data !== null && "matched_gbp_amount" in data
        ? num((data as { matched_gbp_amount?: unknown }).matched_gbp_amount)
        : targetAmount ?? 0;
    const orderRef = typeof data === "object" && data !== null ? text((data as { order_ref?: unknown }).order_ref) : text(target.order_ref);

    reservedTotal = round2(reservedTotal + returnedAmount);
    reservedCount += 1;
    if (orderRef) orderRefs.push(orderRef);
  }

  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/completion-loyalty-rewards");
  revalidatePath("/internal/accounting-command-centre/cash-posting");

  redirectWithResult({
    target: "completion_loyalty",
    success: `Reserved one main-bank OUT for ${reservedCount} loyalty reward(s), total £${reservedTotal.toFixed(2)}${orderRefs.length ? ` on ${orderRefs.join(", ")}` : ""}. Pair the DVA/virtual-card IN before release.`,
  });
}
