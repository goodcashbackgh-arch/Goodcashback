import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function addAmount(map: Record<string, number>, key: string, amount: number) {
  if (!key) return;
  map[key] = (map[key] ?? 0) + amount;
}

export async function GET(request: Request) {
  const supabase = await createClient();
  const { searchParams } = new URL(request.url);
  const importerId = searchParams.get("importer_id") || "";

  let query = supabase
    .from("dva_statement_line_allocation_detail_vw")
    .select("importer_id, allocation_type, allocation_status, supplier_invoice_ref, dispute_id, allocated_gbp_amount")
    .eq("allocation_status", "confirmed")
    .limit(2000);

  if (importerId) query = query.eq("importer_id", importerId);

  const { data, error } = await query;

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const supplierInvoiceAllocatedByRef: Record<string, number> = {};
  const exceptionAllocatedByDisputeId: Record<string, number> = {};

  for (const row of (data ?? []) as Row[]) {
    const allocationType = text(row.allocation_type);
    const amount = num(row.allocated_gbp_amount);

    if (allocationType === "supplier_invoice") {
      addAmount(supplierInvoiceAllocatedByRef, text(row.supplier_invoice_ref), amount);
      continue;
    }

    if (["retailer_refund", "exception_hold", "not_charged_closure", "unmatched_hold"].includes(allocationType)) {
      addAmount(exceptionAllocatedByDisputeId, text(row.dispute_id), amount);
    }
  }

  return NextResponse.json({ supplierInvoiceAllocatedByRef, exceptionAllocatedByDisputeId });
}
