import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = {
  queue_row_id: string;
  document_lane: string | null;
  document_type: string | null;
  source_table: string | null;
  source_id: string | null;
  order_id: string | null;
  order_ref: string | null;
  shipment_batch_id: string | null;
  booking_ref: string | null;
  counterparty_name: string | null;
  amount_gbp: number | string | null;
  currency_code: string | null;
  invoice_type: string | null;
  sage_status: string | null;
  sage_invoice_id: string | null;
  sage_posted_at: string | null;
  readiness_status: string | null;
  blocker: string | null;
  reference_text: string | null;
  notes_text: string | null;
  detail_href: string | null;
  source_payload: Record<string, unknown> | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined, currency = "GBP") {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format(n(value));
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (status.startsWith("blocked")) return "bg-rose-100 text-rose-800";
  if (status.startsWith("ready")) return "bg-emerald-100 text-emerald-800";
  if (status.startsWith("internally_marked")) return "bg-amber-100 text-amber-800";
  if (status.startsWith("sage_confirmation")) return "bg-slate-200 text-slate-800";
  return "bg-amber-100 text-amber-800";
}

function laneLabel(lane: string | null | undefined) {
  if (lane === "customer_sales") return "Customer sales";
  if (lane === "shipper_ap") return "Shipper AP";
  return friendly(lane);
}

function readinessLabel(status: string | null | undefined) {
  if (status === "internally_marked_posted_no_sage_confirmation") return "Internal posted flag only — no Sage confirmation";
  if (status === "sage_confirmation_recorded") return "Sage confirmation recorded";
  if (status === "blocked_sage_tax_mapping_required") return "Blocked — Sage tax mapping required";
  if (status === "ready_for_sage_posting_preview") return "Ready for Sage posting preview";
  if (status === "ready_for_ap_purchase_invoice_draft") return "Ready for AP purchase invoice draft";
  return friendly(status);
}

function sageStatusLabel(row: Row) {
  if (row.sage_status === "posted" && !row.sage_invoice_id && !row.sage_posted_at) return "Internal posted flag only";
  if (row.sage_status === "posted") return "Posted with Sage confirmation";
  return friendly(row.sage_status);
}

function effectiveReadiness(row: Row) {
  if (row.sage_status === "posted" && !row.sage_invoice_id && !row.sage_posted_at) return "internally_marked_posted_no_sage_confirmation";
  if (row.sage_status === "posted") return "sage_confirmation_recorded";
  return row.readiness_status;
}

function effectiveBlocker(row: Row) {
  if (row.sage_status === "posted" && !row.sage_invoice_id && !row.sage_posted_at) return "Legacy/test row has sage_status posted, but no Sage invoice id or posted timestamp.";
  return row.blocker;
}

function matchesFilter(row: Row, lane: string, status: string) {
  const laneOk = lane === "all" || row.document_lane === lane;
  const state = effectiveReadiness(row);
  const activeOk = status === "active" && !state?.startsWith("internally_marked") && !state?.startsWith("sage_confirmation") && row.sage_status !== "void";
  const statusOk =
    activeOk ||
    status === "all" ||
    (status === "blocked" && state?.startsWith("blocked")) ||
    (status === "ready" && state?.startsWith("ready")) ||
    (status === "internal_posted_flag" && state?.startsWith("internally_marked")) ||
    (status === "sage_confirmed" && state?.startsWith("sage_confirmation")) ||
    (status === "draft" && row.sage_status === "draft") ||
    (status === "void" && row.sage_status === "void");
  return laneOk && statusOk;
}

export default async function ReadyForSagePage({ searchParams }: { searchParams?: Promise<{ lane?: string; status?: string }> }) {
  const params = searchParams ? await searchParams : {};
  const lane = params.lane ?? "all";
  const status = params.status ?? "active";

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

  const { data, error } = await (supabase as any).rpc("internal_ready_for_sage_queue_v2");
  const allRows = (data ?? []) as Row[];
  const rows = allRows.filter((row) => matchesFilter(row, lane, status));
  const activeRows = allRows.filter((row) => matchesFilter(row, "all", "active"));
  const customerRows = activeRows.filter((row) => row.document_lane === "customer_sales");
  const apRows = activeRows.filter((row) => row.document_lane === "shipper_ap");
  const blockedRows = activeRows.filter((row) => effectiveReadiness(row)?.startsWith("blocked"));
  const readyRows = activeRows.filter((row) => effectiveReadiness(row)?.startsWith("ready"));
  const legacyRows = allRows.filter((row) => effectiveReadiness(row)?.startsWith("internally_marked"));

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/shipping-control">Shipping control</Link>
            <Link href="/internal/shipping-control/customer-invoice-release">Customer invoice release queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Ready for Sage queue</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                One accounting queue for internal documents that are ready or nearly ready for Sage. This page is read-only for now: it does not test Sage endpoints, post to Sage, clear VAT, or mark anything posted. Legacy/test rows marked posted internally are hidden by default.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Ready for Sage queue unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
          {legacyRows.length > 0 ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{legacyRows.length} legacy/test row(s) are internally marked posted without Sage confirmation. They are hidden in the default Active view.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Active queue rows</p><p className="mt-1 text-2xl font-semibold">{activeRows.length}</p></div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Customer sales</p><p className="mt-1 text-2xl font-semibold">{customerRows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipper AP</p><p className="mt-1 text-2xl font-semibold">{apRows.length}</p></div>
          <div className={`rounded-3xl border p-4 shadow-sm ${blockedRows.length > 0 ? "border-rose-200 bg-rose-50" : "border-slate-200 bg-white"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Ready / blocked</p><p className="mt-1 text-2xl font-semibold">{readyRows.length} / {blockedRows.length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Accounting documents</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Customer sales drafts and shipper/AP purchase invoice intents are shown together with filters. Posting controls stay disabled until Sage mappings and endpoint tests are built.</p>
            </div>
            <form action="/internal/sage-ready" className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:grid-cols-[1fr_1fr_auto]">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Lane<select name="lane" defaultValue={lane} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950"><option value="all">All</option><option value="customer_sales">Customer sales</option><option value="shipper_ap">Shipper AP</option></select></label>
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Status<select name="status" defaultValue={status} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950"><option value="active">Active only</option><option value="all">All including legacy</option><option value="ready">Ready</option><option value="blocked">Blocked</option><option value="draft">Draft</option><option value="internal_posted_flag">Internal posted flag only</option><option value="sage_confirmed">Sage confirmed</option><option value="void">Void</option></select></label>
              <div className="flex items-end gap-2"><button type="submit" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply</button><Link href="/internal/sage-ready" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100">Reset</Link></div>
            </form>
          </div>

          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No Sage-ready rows match these filters.</p> : null}

          <div className="mt-5 grid gap-4 lg:hidden">
            {rows.map((row) => {
              const state = effectiveReadiness(row);
              const blocker = effectiveBlocker(row);
              return (
              <article key={row.queue_row_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">{laneLabel(row.document_lane)}</p>
                    <p className="mt-1 text-lg font-semibold">{row.reference_text ?? row.order_ref ?? row.source_id}</p>
                    <p className="text-sm text-slate-600">{friendly(row.document_type)}</p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-1 text-xs font-semibold ${statusClass(state)}`}>{readinessLabel(state)}</span>
                </div>
                <p className="mt-3 text-sm text-slate-700">{row.counterparty_name ?? "Counterparty"}</p>
                <div className="mt-4 grid grid-cols-2 gap-2 text-sm">
                  <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-3"><p className="text-xs uppercase tracking-wide text-emerald-700">Amount</p><p className="mt-1 font-semibold">{money(row.amount_gbp, row.currency_code ?? "GBP")}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Sage status</p><p className="mt-1 font-semibold">{sageStatusLabel(row)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Order</p><p className="mt-1 font-semibold">{row.order_ref ?? "—"}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Notes</p><p className="mt-1 font-semibold">{row.notes_text || "—"}</p></div>
                </div>
                {blocker ? <p className="mt-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{friendly(blocker)}</p> : null}
                {row.detail_href ? <Link href={row.detail_href} className="mt-4 inline-flex rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800">View detail</Link> : null}
              </article>
              );
            })}
          </div>

          <div className="mt-5 hidden overflow-x-auto rounded-2xl border border-slate-200 lg:block">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Lane / document</th>
                  <th className="px-3 py-2 text-left">Reference</th>
                  <th className="px-3 py-2 text-left">Counterparty</th>
                  <th className="px-3 py-2 text-right">Amount</th>
                  <th className="px-3 py-2 text-left">Sage status</th>
                  <th className="px-3 py-2 text-left">Readiness</th>
                  <th className="px-3 py-2 text-left">Notes</th>
                  <th className="px-3 py-2 text-left">Links</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.map((row) => {
                  const state = effectiveReadiness(row);
                  const blocker = effectiveBlocker(row);
                  return (
                  <tr key={row.queue_row_id}>
                    <td className="px-3 py-3 align-top"><p className="font-semibold">{laneLabel(row.document_lane)}</p><p className="mt-1 text-xs text-slate-500">{friendly(row.document_type)}</p></td>
                    <td className="px-3 py-3 align-top"><p className="font-semibold">{row.reference_text ?? row.order_ref ?? "—"}</p><p className="mt-1 text-xs text-slate-500">{row.order_ref ?? row.booking_ref ?? "—"}</p></td>
                    <td className="px-3 py-3 align-top">{row.counterparty_name ?? "—"}</td>
                    <td className="px-3 py-3 text-right align-top font-semibold">{money(row.amount_gbp, row.currency_code ?? "GBP")}</td>
                    <td className="px-3 py-3 align-top">{sageStatusLabel(row)}</td>
                    <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(state)}`}>{readinessLabel(state)}</span>{blocker ? <p className="mt-1 text-xs text-rose-700">{friendly(blocker)}</p> : null}</td>
                    <td className="px-3 py-3 align-top">{row.notes_text || "—"}</td>
                    <td className="px-3 py-3 align-top">{row.detail_href ? <Link href={row.detail_href} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50">View detail</Link> : <span className="text-xs text-slate-400">—</span>}</td>
                  </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Control rule</h2>
          <p className="mt-2">Create draft means the document is allowed into this queue. Actual Sage posting remains a separate controlled action after tenant tax-rate/account mappings and endpoint testing are proven.</p>
        </section>
      </div>
    </main>
  );
}
