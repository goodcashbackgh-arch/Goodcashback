import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveShippingApportionmentAction } from "../actions";

type PreviewRow = {
  shipping_document_id: string;
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_name: string | null;
  shipper_name: string | null;
  review_status: string | null;
  source_currency_code: string | null;
  source_total_amount: number | string | null;
  existing_allocation_id: string | null;
  existing_allocation_status: string | null;
  existing_approved_at: string | null;
  tracking_submission_id: string | null;
  order_id: string | null;
  order_ref: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  adjusted_net_value_gbp: number | string | null;
  suggested_category_code: string | null;
  suggested_category_label: string | null;
  suggested_category_factor: number | string | null;
  weighted_basis: number | string | null;
  preview_allocated_amount: number | string | null;
  blocker: string | null;
};

type RuleRow = { rule_code: string; label: string; default_factor: number | string; active: boolean };

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined, currency = "GBP") {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency || "GBP" }).format(n(value));
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function statusClass(status: string | null | undefined) {
  if (["accepted_current", "approved"].includes(status ?? "")) return "bg-emerald-100 text-emerald-800";
  if (status) return "bg-amber-100 text-amber-800";
  return "bg-slate-100 text-slate-700";
}

export default async function ShippingApportionmentPage({ params, searchParams }: { params: Promise<{ shipping_document_id: string }>; searchParams?: Promise<{ success?: string; error?: string }> }) {
  const { shipping_document_id: shippingDocumentId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const [{ data, error }, { data: rulesData }] = await Promise.all([
    (supabase as any).rpc("internal_shipping_apportionment_preview_v1", { p_shipping_document_id: shippingDocumentId }),
    supabase.from("shipping_category_weight_rules").select("rule_code,label,default_factor,active").eq("active", true).order("default_factor", { ascending: true }),
  ]);

  const rows = (data ?? []) as PreviewRow[];
  const rules = (rulesData ?? []) as RuleRow[];
  const first = rows[0] ?? null;
  const blockers = Array.from(new Set(rows.map((row) => row.blocker).filter(Boolean))) as string[];
  const canApprove = rows.length > 0 && blockers.length === 0 && first?.review_status === "accepted_current";
  const sourceCurrency = first?.source_currency_code ?? "GBP";
  const sourceTotal = n(first?.source_total_amount);
  const itemQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const weightedTotal = rows.reduce((sum, row) => sum + n(row.weighted_basis), 0);
  const previewAllocatedTotal = rows.reduce((sum, row) => sum + n(row.preview_allocated_amount), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control/shipper-documents">← Shipper document queue</Link>
            <Link href={`/internal/shipping-control/shipper-documents/${shippingDocumentId}`}>Review document</Link>
            <Link href="/internal/shipping-control">Shipping control</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipping cost apportionment</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Supervisor-only preview and approval. This allocates the accepted shipper charge document across the shipment package/item scope. It does not post to Sage, create COS/BOL/POD, or clear VAT.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{error.message}</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-5">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p><p className="mt-1 text-xl font-semibold">{first.booking_ref ?? first.shipment_batch_id}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-1 text-xl font-semibold">{first.importer_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Document status</p><span className={`mt-1 inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(first.review_status)}`}>{friendly(first.review_status)}</span></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Charge amount</p><p className="mt-1 text-xl font-semibold">{money(sourceTotal, sourceCurrency)}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Existing allocation</p><p className="mt-1 text-xl font-semibold">{first.existing_allocation_id ? friendly(first.existing_allocation_status) : "None"}</p>{first.existing_approved_at ? <p className="mt-1 text-xs text-slate-500">{shortDate(first.existing_approved_at)}</p> : null}</div>
            </section>

            {blockers.length > 0 ? (
              <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm text-amber-900 shadow-sm">
                <h2 className="text-lg font-semibold">Blocked before approval</h2>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {blockers.map((blocker) => <li key={blocker}>{friendly(blocker)}</li>)}
                </ul>
              </section>
            ) : null}

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">Category-weighted allocation preview</h2>
                  <p className="mt-2 text-sm leading-6 text-slate-600">Default method uses adjusted shipped value × category factor. Supervisor can override category with a reason before approval.</p>
                </div>
                <div className="grid gap-2 text-sm sm:grid-cols-3">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Item qty</p><p className="font-semibold">{qty(itemQty)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Weighted basis</p><p className="font-semibold">{weightedTotal.toFixed(4)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Preview total</p><p className="font-semibold">{money(previewAllocatedTotal, sourceCurrency)}</p></div>
                </div>
              </div>

              <form action={approveShippingApportionmentAction} className="mt-5 space-y-5">
                <input type="hidden" name="shipping_document_id" value={shippingDocumentId} />
                <div className="overflow-x-auto rounded-2xl border border-slate-200">
                  <table className="min-w-full divide-y divide-slate-200 text-sm">
                    <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                      <tr>
                        <th className="px-3 py-2 text-left">Order / package</th>
                        <th className="px-3 py-2 text-left">Item</th>
                        <th className="px-3 py-2 text-right">Qty</th>
                        <th className="px-3 py-2 text-right">Adjusted value</th>
                        <th className="px-3 py-2 text-left">Category</th>
                        <th className="px-3 py-2 text-right">Factor</th>
                        <th className="px-3 py-2 text-right">Allocated shipping</th>
                        <th className="px-3 py-2 text-left">Override reason</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100 bg-white">
                      {rows.map((row, index) => (
                        <tr key={`${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                          <td className="px-3 py-3 align-top"><p className="font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p><p className="text-xs text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p></td>
                          <td className="px-3 py-3 align-top"><p className="font-medium">{row.item_description ?? "Unlabelled item"}</p>{row.blocker ? <p className="mt-1 text-xs font-semibold text-amber-700">{friendly(row.blocker)}</p> : null}</td>
                          <td className="px-3 py-3 text-right align-top">{qty(row.qty_allocated)}</td>
                          <td className="px-3 py-3 text-right align-top">{money(row.adjusted_net_value_gbp, "GBP")}</td>
                          <td className="px-3 py-3 align-top">
                            <input type="hidden" name="tracking_submission_id" value={row.tracking_submission_id ?? ""} />
                            <input type="hidden" name="supplier_invoice_line_id" value={row.supplier_invoice_line_id ?? ""} />
                            <select name="category_code" defaultValue={row.suggested_category_code ?? "unclassified"} className="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" disabled={!canApprove}>
                              {rules.map((rule) => <option key={rule.rule_code} value={rule.rule_code}>{rule.label} × {n(rule.default_factor).toFixed(1)}</option>)}
                            </select>
                          </td>
                          <td className="px-3 py-3 text-right align-top">{n(row.suggested_category_factor).toFixed(3)}</td>
                          <td className="px-3 py-3 text-right align-top font-semibold">{money(row.preview_allocated_amount, sourceCurrency)}</td>
                          <td className="px-3 py-3 align-top"><input name="override_reason" placeholder="Required if changing category" className="w-56 rounded-xl border border-slate-300 px-3 py-2 text-sm" disabled={!canApprove} /></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>

                <label className="block text-sm">
                  <span className="text-xs font-semibold uppercase tracking-wide text-slate-500">Approval note</span>
                  <textarea name="approval_note" rows={3} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Optional supervisor note for apportionment basis" disabled={!canApprove} />
                </label>

                <div className="flex flex-wrap items-center gap-3">
                  <button type="submit" disabled={!canApprove} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800 disabled:cursor-not-allowed disabled:bg-slate-300">Approve apportionment basis</button>
                  <p className="text-sm text-slate-600">Approval stores the basis snapshot. It does not post to Sage or create COS/export evidence.</p>
                </div>
              </form>
            </section>
          </>
        ) : !error ? (
          <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm text-amber-900 shadow-sm">No apportionment preview rows found for this document.</section>
        ) : null}
      </div>
    </main>
  );
}
