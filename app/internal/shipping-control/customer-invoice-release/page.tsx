import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { createCustomerInvoiceDrafts } from "./actions";

type Row = {
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_name: string | null;
  shipper_name: string | null;
  proposed_invoice_type: string | null;
  customer_action_label: string | null;
  sales_invoice_state: string | null;
  vat_code: string | null;
  proposed_amount_gbp: number | string | null;
  proposed_goods_amount_gbp: number | string | null;
  proposed_shipping_amount_gbp: number | string | null;
  order_count: number | string | null;
  line_count: number | string | null;
  ready_line_count: number | string | null;
  blocker_count: number | string | null;
  blockers: string[] | null;
  readiness_status: string | null;
  first_order_ref: string | null;
  order_refs: string | null;
  created_draft_count: number | string | null;
  posted_invoice_count: number | string | null;
  queue_action: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(n(value));
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (status === "ready_to_create_draft") return "bg-emerald-100 text-emerald-800";
  if (status === "draft_exists") return "bg-sky-100 text-sky-800";
  if (status === "posted_exists") return "bg-slate-200 text-slate-800";
  if (status === "blocked") return "bg-rose-100 text-rose-800";
  return "bg-amber-100 text-amber-800";
}

function actionLabel(status: string | null | undefined) {
  if (status === "ready_to_create_draft") return "Ready for draft creation";
  if (status === "draft_exists") return "Draft already exists";
  if (status === "posted_exists") return "Invoice already posted";
  if (status === "blocked") return "Blocked";
  return friendly(status);
}

export default async function CustomerInvoiceReleaseQueuePage({ searchParams }: { searchParams?: Promise<{ result?: string; created?: string; skipped?: string; message?: string }> }) {
  const params = searchParams ? await searchParams : {};
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

  const { data, error } = await (supabase as any).rpc("internal_customer_invoice_release_queue_v1");
  const rows = (data ?? []) as Row[];
  const readyRows = rows.filter((row) => row.readiness_status === "ready_to_create_draft");
  const blockedRows = rows.filter((row) => row.readiness_status === "blocked");
  const draftRows = rows.filter((row) => row.readiness_status === "draft_exists");
  const totalAmount = readyRows.reduce((sum, row) => sum + n(row.proposed_amount_gbp), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            <Link href="/internal">Internal dashboard</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Customer invoice release queue</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Focused supervisor queue for stable customer invoice intents. Create draft records only for ready rows. This does not post to Sage, clear VAT, generate COS/BOL/POD, or close export evidence.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Queue unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
          {params.result === "created" ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">Draft creation complete: {params.created ?? "0"} created, {params.skipped ?? "0"} skipped.</p> : null}
          {params.result === "error" ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">Draft creation failed: {params.message ?? "Unknown error"}</p> : null}
          {params.result === "no_ready_rows_selected" ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">No ready rows selected.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Queue rows</p><p className="mt-1 text-2xl font-semibold">{rows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Ready</p><p className="mt-1 text-2xl font-semibold">{readyRows.length}</p><p className="mt-1 text-xs text-slate-600">{money(totalAmount)}</p></div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Draft exists</p><p className="mt-1 text-2xl font-semibold">{draftRows.length}</p></div>
          <div className="rounded-3xl border border-rose-200 bg-rose-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Blocked</p><p className="mt-1 text-2xl font-semibold">{blockedRows.length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Ready and blocked invoice intents</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Use Preview to inspect a booking. Use the bulk action when the ready set looks right.</p>
            </div>
            <form action={createCustomerInvoiceDrafts}>
              {readyRows.map((row) => <input key={row.shipment_batch_id} type="hidden" name="shipment_batch_id" value={row.shipment_batch_id} />)}
              <button disabled={readyRows.length === 0 || Boolean(error)} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800 disabled:cursor-not-allowed disabled:border disabled:border-dashed disabled:border-slate-300 disabled:bg-slate-100 disabled:text-slate-500">
                Create drafts for all ready ({readyRows.length})
              </button>
            </form>
          </div>

          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No customer invoice intents found yet.</p> : null}

          <div className="mt-5 grid gap-4 lg:hidden">
            {rows.map((row) => (
              <article key={row.shipment_batch_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Booking / order</p>
                    <p className="mt-1 text-lg font-semibold">{row.booking_ref ?? row.shipment_batch_id}</p>
                    <p className="text-sm text-slate-600">{row.order_refs ?? row.first_order_ref ?? "—"}</p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>{actionLabel(row.readiness_status)}</span>
                </div>
                <p className="mt-3 text-sm text-slate-700">{row.importer_name ?? "Importer"} · {row.shipper_name ?? "Shipper"}</p>
                <div className="mt-4 grid grid-cols-2 gap-2 text-sm">
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Action</p><p className="mt-1 font-semibold">{row.customer_action_label ?? friendly(row.proposed_invoice_type)}</p></div>
                  <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-3"><p className="text-xs uppercase tracking-wide text-emerald-700">Amount</p><p className="mt-1 font-semibold">{money(row.proposed_amount_gbp)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Lines</p><p className="mt-1 font-semibold">{n(row.ready_line_count)} / {n(row.line_count)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">State</p><p className="mt-1 font-semibold">{friendly(row.sales_invoice_state)}</p></div>
                </div>
                {n(row.blocker_count) > 0 ? <p className="mt-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{(row.blockers ?? []).map(friendly).join(", ")}</p> : null}
                <div className="mt-4 flex flex-wrap gap-2">
                  <Link href={`/internal/shipping-control/customer-invoice/${row.shipment_batch_id}`} className="rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 text-xs font-semibold text-sky-900">Preview intent</Link>
                  <Link href={`/internal/shipping-control/${row.shipment_batch_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800">Batch detail</Link>
                </div>
              </article>
            ))}
          </div>

          <div className="mt-5 hidden overflow-x-auto rounded-2xl border border-slate-200 lg:block">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Booking / order</th>
                  <th className="px-3 py-2 text-left">Parties</th>
                  <th className="px-3 py-2 text-left">Customer action</th>
                  <th className="px-3 py-2 text-right">Amount</th>
                  <th className="px-3 py-2 text-right">Lines</th>
                  <th className="px-3 py-2 text-left">State</th>
                  <th className="px-3 py-2 text-left">Next</th>
                  <th className="px-3 py-2 text-left">Links</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.map((row) => (
                  <tr key={row.shipment_batch_id}>
                    <td className="px-3 py-3 align-top"><p className="font-semibold">{row.booking_ref ?? row.shipment_batch_id}</p><p className="mt-1 text-xs text-slate-500">{row.order_refs ?? row.first_order_ref ?? "—"}</p></td>
                    <td className="px-3 py-3 align-top"><p>{row.importer_name ?? "Importer"}</p><p className="mt-1 text-xs text-slate-500">{row.shipper_name ?? "Shipper"}</p></td>
                    <td className="px-3 py-3 align-top">{row.customer_action_label ?? friendly(row.proposed_invoice_type)}</td>
                    <td className="px-3 py-3 text-right align-top font-semibold">{money(row.proposed_amount_gbp)}</td>
                    <td className="px-3 py-3 text-right align-top">{n(row.ready_line_count)} / {n(row.line_count)}</td>
                    <td className="px-3 py-3 align-top"><p>{friendly(row.sales_invoice_state)}</p>{n(row.blocker_count) > 0 ? <p className="mt-1 text-xs text-rose-700">{(row.blockers ?? []).map(friendly).join(", ")}</p> : null}</td>
                    <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>{actionLabel(row.readiness_status)}</span></td>
                    <td className="px-3 py-3 align-top"><div className="flex flex-col gap-2"><Link href={`/internal/shipping-control/customer-invoice/${row.shipment_batch_id}`} className="rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 text-xs font-semibold text-sky-900">Preview intent</Link><Link href={`/internal/shipping-control/${row.shipment_batch_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800">Batch detail</Link></div></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Control rule</h2>
          <p className="mt-2">This queue creates internal draft customer invoice records only. It does not post to Sage, clear VAT/export evidence, generate COS/BOL/POD, or close the order.</p>
        </section>
      </div>
    </main>
  );
}
