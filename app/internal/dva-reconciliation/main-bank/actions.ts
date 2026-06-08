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

  const lineRemaining = round2(num(selectedLine.remaining_gbp));
  const targetTotal = round2(selectedTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));

  if (shippingDocumentIds.length > 1 && targetTotal > lineRemaining + 0.01) {
    redirectWithResult({ error: `Selected shipper invoices total £${targetTotal.toFixed(2)}, which exceeds the remaining bank line amount £${lineRemaining.toFixed(2)}.` });
  }

  let allocatedTotal = 0;
  let allocatedCount = 0;

  for (const target of selectedTargets) {
    const targetId = text(target.shipping_document_id);
    const allocationAmount = shippingDocumentIds.length === 1 && amountRaw ? amount : round2(num(target.remaining_gbp));

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
    redirectWithResult({ error: "Please sign in again before matching the loyalty funding line.", target: "completion_loyalty" });
  }

  const statementLineId = readString(formData, "dva_statement_line_id");
  const orderId = readString(formData, "order_id");
  const amountRaw = readString(formData, "reward_amount_gbp");
  const amount = amountRaw ? Number(amountRaw) : null;
  const notes = readString(formData, "notes") || "Main-bank funding matched to completion loyalty reward.";

  if (!statementLineId || !orderId) {
    redirectWithResult({ error: "Select one main-bank OUT line and one completion loyalty target.", target: "completion_loyalty" });
  }

  if (amountRaw && (!Number.isFinite(amount) || Number(amount) <= 0)) {
    redirectWithResult({ error: "Reward release amount must be greater than zero.", target: "completion_loyalty" });
  }

  const { data, error } = await supabase.rpc("staff_match_main_bank_line_to_completion_loyalty_v1", {
    p_dva_statement_line_id: statementLineId,
    p_order_id: orderId,
    p_reward_amount_gbp: amount,
    p_notes: notes,
  });

  if (error) redirectWithResult({ error: error.message, target: "completion_loyalty" });

  const releasedAmount =
    typeof data === "object" && data !== null && "matched_gbp_amount" in data
      ? num((data as { matched_gbp_amount?: unknown }).matched_gbp_amount)
      : amount ?? 0;
  const orderRef = typeof data === "object" && data !== null ? text((data as { order_ref?: unknown }).order_ref) : "";

  revalidatePath("/internal/dva-reconciliation/main-bank");
  revalidatePath("/internal/completion-loyalty-rewards");
  revalidatePath("/internal/accounting-command-centre/cash-posting");

  redirectWithResult({
    target: "completion_loyalty",
    success: `Matched main-bank funding and released ${releasedAmount.toFixed(2)} loyalty credit${orderRef ? ` for ${orderRef}` : ""}.`,
  });
}
