import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { resolveSupplierInvoiceLineNonPhysicalAction } from "../nonPhysicalActions";

type SupplierInvoiceLine = {
  id: string;
  line_order: number;
  line_source: string;
  description: string | null;
  qty: number | null;
  amount_inc_vat_gbp: number | null;
  eligible_for_invoice_yn: string | null;
};

type Resolution = {
  supplier_invoice_line_id: string;
  financial_type: string;
  amount_gbp: number | null;
  qty_reported: number | null;
  notes: string | null;
  resolved_at: string | null;
};

function gbp(value: number | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function suggestedFinancialType(description: string | null | undefined, amount: number | null | undefined) {
  const text = String(description ?? "").toLowerCase();
  const numericAmount = Number(amount ?? 0);
  if (text.includes("delivery") || text.includes("shipping") || text.includes("postage") || text.includes("carriage")) {
    return Math.abs(numericAmount) < 0.01 ? "zero_value_delivery" : "delivery";
  }
  if (text.includes("discount") || text.includes("promo") || text.includes("voucher") || text.includes("coupon")) return "discount";
  if (text.includes("fee") || text.includes("charge")) return "fee";
  if (text.includes("rounding")) return "rounding";
  return "other_non_physical";
}

export default async function NonPhysicalInvoiceLineResolutionPage({
  params,
}: {
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) redirect("/auth/check");

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id, order_ref")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) redirect("/importer");

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (!access) redirect("/importer");

  const { data: invoice } = await supabase
    .from("supplier_invoices")
    .select("id, invoice_ref, uploaded_at")
    .eq("order_id", orderId)
    .or("review_status.is.null,review_status.not.in.(rejected_resubmit_required,duplicate_blocked,superseded)")
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: lines } = invoice
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, line_order, line_source, description, qty, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] as SupplierInvoiceLine[] };

  const invoiceLines = (lines ?? []) as SupplierInvoiceLine[];
  const lineIds = invoiceLines.map((line) => line.id);

  const { data: disputeLinks } = lineIds.length > 0
    ? await supabase
        .from("dispute_lines")
        .select("supplier_invoice_line_id, resolved_at")
        .in("supplier_invoice_line_id", lineIds)
        .is("resolved_at", null)
    : { data: [] as Array<{ supplier_invoice_line_id: string; resolved_at: string | null }> };

  const disputeLineIds = new Set((disputeLinks ?? []).map((row) => row.supplier_invoice_line_id));

  const { data: resolutions } = lineIds.length > 0
    ? await supabase
        .from("supplier_invoice_line_resolutions")
        .select("supplier_invoice_line_id, financial_type, amount_gbp, qty_reported, notes, resolved_at")
        .in("supplier_invoice_line_id", lineIds)
        .eq("active", true)
    : { data: [] as Resolution[] };

  const resolutionByLineId = new Map<string, Resolution>();
  for (const resolution of (resolutions ?? []) as Resolution[]) {
    resolutionByLineId.set(resolution.supplier_invoice_line_id, resolution);
  }

  const unresolvedLines = invoiceLines.filter(
    (line) => !isProgressed(line.eligible_for_invoice_yn) && !disputeLineIds.has(line.id) && !resolutionByLineId.has(line.id),
  );

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-5xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href={`/importer/reconciliation/${orderId}`} className="text-sm font-semibold text-sky-700 underline">← Back to reconciliation</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Non-physical invoice lines</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight">Order {order.order_ref ?? orderId}</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Use this page only for invoice rows that are not physical goods: delivery, shipping, discount, fee, rounding, or zero-value informational rows. Physical products must be progressed or branched into an exception case from the reconciliation page.
          </p>
          {invoice ? <p className="mt-3 text-sm text-slate-600">Current invoice: <span className="font-semibold">{invoice.invoice_ref}</span></p> : <p className="mt-3 text-sm text-rose-700">No active supplier invoice found.</p>}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Unresolved non-progressed lines</h2>
          {unresolvedLines.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800">No unprogressed, unexceptioned, unparked lines are currently available.</p>
          ) : (
            <div className="mt-4 space-y-4">
              {unresolvedLines.map((line) => {
                const suggestion = suggestedFinancialType(line.description, line.amount_inc_vat_gbp);
                return (
                  <article key={line.id} className="rounded-2xl border border-slate-200 bg-white p-4">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="text-sm font-semibold text-slate-900">Line {line.line_order} · {line.line_source}</p>
                        <p className="mt-1 text-sm text-slate-700">{line.description ?? "No description"}</p>
                        <p className="mt-1 text-xs text-slate-500">Qty {line.qty ?? 0} · {gbp(line.amount_inc_vat_gbp)} · eligible {line.eligible_for_invoice_yn ?? "N"}</p>
                      </div>
                      <form action={resolveSupplierInvoiceLineNonPhysicalAction} className="flex flex-wrap items-center gap-2 rounded-xl border border-sky-200 bg-sky-50 px-3 py-2">
                        <input type="hidden" name="order_id" value={orderId} />
                        <input type="hidden" name="line_id" value={line.id} />
                        <select name="financial_type" defaultValue={suggestion} className="rounded-lg border border-sky-200 bg-white px-2 py-1 text-xs">
                          <option value="zero_value_delivery">zero-value delivery</option>
                          <option value="delivery">delivery</option>
                          <option value="discount">discount</option>
                          <option value="fee">fee</option>
                          <option value="rounding">rounding</option>
                          <option value="other_non_physical">other non-physical</option>
                        </select>
                        <input name="notes" className="w-48 rounded-lg border border-sky-200 px-2 py-1 text-xs" placeholder="Optional note" />
                        <button type="submit" className="rounded-lg bg-sky-700 px-3 py-1.5 text-xs font-semibold text-white hover:bg-sky-600">Park non-physical</button>
                      </form>
                    </div>
                  </article>
                );
              })}
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Already parked</h2>
          {(resolutions ?? []).length === 0 ? (
            <p className="mt-4 text-sm text-slate-600">No non-physical lines have been parked for this invoice yet.</p>
          ) : (
            <div className="mt-4 space-y-3">
              {((resolutions ?? []) as Resolution[]).map((resolution) => {
                const line = invoiceLines.find((candidate) => candidate.id === resolution.supplier_invoice_line_id);
                return (
                  <article key={resolution.supplier_invoice_line_id} className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm">
                    <p className="font-semibold text-sky-950">Line {line?.line_order ?? "?"} · {resolution.financial_type}</p>
                    <p className="mt-1 text-sky-900">{line?.description ?? "No description"}</p>
                    <p className="mt-1 text-xs text-sky-800">Qty reported {resolution.qty_reported ?? 0} · amount {gbp(resolution.amount_gbp)} · not sent to tracking/shipper</p>
                    {resolution.notes ? <p className="mt-1 text-xs text-sky-800">Note: {resolution.notes}</p> : null}
                  </article>
                );
              })}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
