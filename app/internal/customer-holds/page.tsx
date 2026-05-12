import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { createCustomerReviewLinkAction, reviewCustomerHoldAction } from "./actions";

type HoldRow = {
  hold_request_id: string;
  order_id: string;
  order_ref: string | null;
  importer_name: string | null;
  retailer_name: string | null;
  requested_scope: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  line_description: string | null;
  line_qty: number | string | null;
  line_amount_inc_vat_gbp: number | string | null;
  reason: string | null;
  customer_contact_label: string | null;
  status: string | null;
  supervisor_review_note: string | null;
  created_at: string | null;
  reviewed_at: string | null;
};

type OrderContext = {
  id: string;
  total_qty_declared: number | string | null;
  order_total_gbp_declared: number | string | null;
  quote_total_ghs?: number | string | null;
};

type OrderScreenshot = {
  order_id: string;
  screenshot_url: string | null;
  display_order: number | null;
  note: string | null;
};

function money(value: number | string | null | undefined, currency = "GBP") {
  const parsed = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format(Number.isFinite(parsed) ? parsed : 0);
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function statusClass(status: string | null | undefined) {
  if (status === "supervisor_approved") return "bg-amber-100 text-amber-900";
  if (status === "requested") return "bg-sky-100 text-sky-900";
  if (status === "rejected") return "bg-rose-100 text-rose-900";
  if (["resolved", "converted_to_exception", "superseded"].includes(String(status ?? ""))) return "bg-emerald-100 text-emerald-900";
  return "bg-slate-100 text-slate-700";
}

function groupScreenshots(rows: OrderScreenshot[]) {
  const grouped = new Map<string, OrderScreenshot[]>();
  rows.forEach((row) => {
    const existing = grouped.get(row.order_id) ?? [];
    existing.push(row);
    grouped.set(row.order_id, existing);
  });
  return grouped;
}

export default async function InternalCustomerHoldsPage({
  searchParams,
}: {
  searchParams?: Promise<{ success?: string; error?: string; link?: string; include_closed?: string }>;
}) {
  const params = searchParams ? await searchParams : {};
  const includeClosed = params.include_closed === "true";
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

  const { data, error } = await (supabase as any).rpc("internal_customer_pre_shipment_holds_v1", {
    p_include_closed: includeClosed,
  });

  const rows = (data ?? []) as HoldRow[];
  const orderIds = Array.from(new Set(rows.map((row) => row.order_id).filter(Boolean)));

  const { data: orderContextRows } = orderIds.length > 0
    ? await supabase
        .from("orders")
        .select("id,total_qty_declared,order_total_gbp_declared,quote_total_ghs")
        .in("id", orderIds)
    : { data: [] as OrderContext[] };

  const { data: screenshotRows } = orderIds.length > 0
    ? await supabase
        .from("order_screenshots")
        .select("order_id,screenshot_url,display_order,note")
        .in("order_id", orderIds)
        .order("display_order", { ascending: true })
    : { data: [] as OrderScreenshot[] };

  const orderContextById = new Map((orderContextRows ?? []).map((order) => [order.id, order as OrderContext]));
  const screenshotsByOrderId = groupScreenshots((screenshotRows ?? []) as OrderScreenshot[]);

  const openRows = rows.filter((row) => ["requested", "supervisor_approved"].includes(String(row.status ?? "")));
  const approvedRows = rows.filter((row) => row.status === "supervisor_approved");
  const requestedRows = rows.filter((row) => row.status === "requested");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/sage-ready">Ready for Sage queue</Link>
            <Link href="/shipper">Shipper dashboard</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Customer pre-shipment holds</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Review customer hold requests before shipment. Approved holds block shipment/customer invoice/Sage readiness until resolved or converted into the existing refund/replacement/no-charge exception path.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {params.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{params.success}</p> : null}
          {params.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-900">{params.error}</p> : null}
          {params.link ? (
            <div className="mt-4 rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-950">
              <p className="font-semibold">Customer review link</p>
              <p className="mt-1 break-all">{params.link}</p>
            </div>
          ) : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Customer hold queue unavailable: {error.message}. Apply the latest migration before testing this page.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Open holds</p><p className="mt-1 text-2xl font-semibold">{openRows.length}</p></div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Requested</p><p className="mt-1 text-2xl font-semibold">{requestedRows.length}</p></div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Approved set-aside</p><p className="mt-1 text-2xl font-semibold">{approvedRows.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Showing closed?</p><p className="mt-1 text-2xl font-semibold">{includeClosed ? "Yes" : "No"}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Create customer review link</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">Paste an order id to create or reuse a secure customer review link. This does not expose the importer/operator page.</p>
          <form action={createCustomerReviewLinkAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_auto]">
            <input name="order_id" required className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Order UUID" />
            <button className="rounded-xl bg-slate-900 px-5 py-2 text-sm font-semibold text-white hover:bg-slate-800">Create / reuse link</button>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Hold worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Approve only where shipment or final invoice release genuinely needs to be stopped. Use resolve when the hold has been cleared or converted into the existing exception path.</p>
            </div>
            <Link href={includeClosed ? "/internal/customer-holds" : "/internal/customer-holds?include_closed=true"} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">
              {includeClosed ? "Hide closed" : "Show closed"}
            </Link>
          </div>

          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No customer hold requests match this view.</p> : null}

          <div className="mt-5 grid gap-4">
            {rows.map((row) => {
              const orderContext = orderContextById.get(row.order_id);
              const screenshots = screenshotsByOrderId.get(row.order_id) ?? [];

              return (
              <article key={row.hold_request_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h3 className="text-lg font-semibold">{row.order_ref ?? row.order_id}</h3>
                      <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.status)}`}>{friendly(row.status)}</span>
                      <span className="rounded-full bg-white px-2 py-1 text-xs font-semibold text-slate-700">{friendly(row.requested_scope)} hold</span>
                    </div>
                    <p className="mt-1 text-sm text-slate-600">{row.importer_name ?? "Importer"} · {row.retailer_name ?? "Retailer"}</p>
                    <p className="mt-3 text-sm leading-6 text-slate-800">{row.reason}</p>
                    {row.customer_contact_label ? <p className="mt-2 text-xs text-slate-500">Customer label: {row.customer_contact_label}</p> : null}
                  </div>
                  <div className="grid gap-2 text-sm sm:grid-cols-3 lg:min-w-[520px]">
                    <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Tracking</p><p className="mt-1 font-semibold">{row.tracking_ref ?? "—"}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Line</p><p className="mt-1 font-semibold">{row.line_description ?? "—"}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Line value</p><p className="mt-1 font-semibold">{row.supplier_invoice_line_id ? `${row.line_qty ?? "—"} · ${money(row.line_amount_inc_vat_gbp)}` : "—"}</p></div>
                  </div>
                </div>

                <div className="mt-4 grid gap-3 rounded-2xl border border-slate-200 bg-white p-3 text-sm md:grid-cols-3">
                  <div>
                    <p className="text-xs uppercase tracking-wide text-slate-500">Declared order qty</p>
                    <p className="mt-1 font-semibold text-slate-950">{orderContext?.total_qty_declared ?? "—"}</p>
                  </div>
                  <div>
                    <p className="text-xs uppercase tracking-wide text-slate-500">Declared goods value</p>
                    <p className="mt-1 font-semibold text-slate-950">{money(orderContext?.order_total_gbp_declared)}</p>
                  </div>
                  <div>
                    <p className="text-xs uppercase tracking-wide text-slate-500">Original screenshots</p>
                    <p className="mt-1 font-semibold text-slate-950">{screenshots.length}</p>
                  </div>
                </div>

                <div className="mt-4 rounded-2xl border border-slate-200 bg-white p-3">
                  <div className="flex items-center justify-between gap-3">
                    <p className="text-sm font-semibold text-slate-950">Original order screenshots</p>
                    <Link href={`/importer/orders/${row.order_id}/operations`} className="text-xs font-semibold text-sky-700">Open operations</Link>
                  </div>
                  {screenshots.length === 0 ? (
                    <p className="mt-3 rounded-xl bg-slate-50 p-3 text-sm text-slate-600">No order screenshots are visible here. Open order operations to verify whether evidence exists or whether storage/RLS is blocking staff visibility.</p>
                  ) : (
                    <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                      {screenshots.map((shot, index) => (
                        <a key={`${shot.screenshot_url ?? index}-${index}`} href={shot.screenshot_url ?? "#"} target="_blank" rel="noreferrer" className="group rounded-xl border border-slate-200 bg-slate-50 p-2 hover:bg-white">
                          {shot.screenshot_url ? (
                            <img src={shot.screenshot_url} alt={shot.note ?? `Order screenshot ${index + 1}`} className="h-40 w-full rounded-lg object-cover object-top" />
                          ) : (
                            <div className="flex h-40 items-center justify-center rounded-lg bg-slate-100 text-sm text-slate-500">No preview</div>
                          )}
                          <p className="mt-2 text-xs font-semibold text-sky-700 group-hover:underline">View screenshot {shot.display_order ?? index + 1}</p>
                        </a>
                      ))}
                    </div>
                  )}
                </div>

                {row.supervisor_review_note ? <p className="mt-4 rounded-xl border border-slate-200 bg-white p-3 text-sm text-slate-700"><span className="font-semibold">Review note:</span> {row.supervisor_review_note}</p> : null}

                <form action={reviewCustomerHoldAction} className="mt-4 grid gap-3 rounded-2xl border border-slate-200 bg-white p-3 md:grid-cols-[180px_1fr_auto]">
                  <input type="hidden" name="hold_request_id" value={row.hold_request_id} />
                  <select name="decision" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue="">
                    <option value="" disabled>Decision</option>
                    <option value="approve">Approve hold</option>
                    <option value="reject">Reject hold</option>
                    <option value="resolve">Resolve / cleared</option>
                    <option value="supersede">Supersede</option>
                  </select>
                  <input name="review_note" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Review note / instruction" />
                  <button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save</button>
                </form>

                <div className="mt-3 flex flex-wrap gap-3 text-xs font-semibold text-sky-700">
                  <Link href={`/importer/orders/${row.order_id}/operations`}>Operator order operations</Link>
                  <Link href={`/importer/reconciliation/${row.order_id}`}>Operator reconciliation</Link>
                  <Link href={`/internal/status-control/pre-sage-financial-readiness`}>Pre-Sage readiness</Link>
                </div>
              </article>
              );
            })}
          </div>
        </section>
      </div>
    </main>
  );
}
