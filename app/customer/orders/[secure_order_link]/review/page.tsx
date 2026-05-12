import { createClient } from "@/utils/supabase/server";
import { narrowCustomerHoldRequestAction, submitCustomerHoldRequestAction } from "./actions";

type TrackingRow = {
  id: string;
  courier_name?: string | null;
  tracking_ref?: string | null;
  tracking_date?: string | null;
  is_final_delivery_yn?: boolean | null;
};

type LineRow = {
  id: string;
  supplier_invoice_id?: string | null;
  invoice_ref?: string | null;
  description?: string | null;
  size?: string | null;
  retailer_sku?: unknown;
  qty?: number | string | null;
  amount_inc_vat_gbp?: number | string | null;
  eligible_for_invoice_yn?: string | null;
};

type HoldRow = {
  id: string;
  requested_scope?: string | null;
  tracking_submission_id?: string | null;
  supplier_invoice_line_id?: string | null;
  narrowed_from_hold_request_id?: string | null;
  status?: string | null;
  reason?: string | null;
  created_at?: string | null;
  supervisor_review_note?: string | null;
};

type ReviewPayload = {
  order?: {
    id?: string | null;
    order_ref?: string | null;
    retailer_name?: string | null;
    status?: string | null;
    order_type?: string | null;
    total_qty_declared?: number | string | null;
  };
  tracking?: TrackingRow[];
  lines?: LineRow[];
  holds?: HoldRow[];
};

function money(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number.isFinite(parsed) ? parsed : 0);
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function safeText(value: unknown) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.toLowerCase() === "[object object]") return null;
  return trimmed;
}

function statusClass(status: string | null | undefined) {
  if (status === "supervisor_approved") return "bg-amber-100 text-amber-900";
  if (status === "requested") return "bg-sky-100 text-sky-900";
  if (status === "rejected") return "bg-rose-100 text-rose-900";
  if (["resolved", "converted_to_exception", "superseded"].includes(String(status ?? ""))) return "bg-emerald-100 text-emerald-900";
  return "bg-slate-100 text-slate-700";
}

function LineCard({ line, mode = "selectable" }: { line: LineRow; mode?: "selectable" | "held" | "pending" }) {
  const size = safeText(line.size);
  const sku = safeText(line.retailer_sku);
  const locked = mode !== "selectable";

  return (
    <label className={`flex gap-3 rounded-2xl border p-4 ${locked ? "border-emerald-200 bg-emerald-50 text-emerald-950" : "cursor-pointer border-slate-200 bg-slate-50 hover:bg-white"}`}>
      {locked ? (
        <span className="mt-1 h-fit rounded-full bg-emerald-100 px-2 py-1 text-xs font-semibold text-emerald-800">{mode === "pending" ? "Pending" : "Held"}</span>
      ) : (
        <input type="checkbox" name="supplier_invoice_line_ids" value={line.id} className="mt-1 h-5 w-5 rounded border-slate-300 text-slate-900" />
      )}
      <span className="min-w-0 flex-1 text-sm">
        <span className="block font-semibold leading-5">{line.description ?? "Item line"}</span>
        <span className="mt-1 block text-slate-600">Qty {line.qty ?? "—"} · {money(line.amount_inc_vat_gbp)}</span>
        <span className="mt-1 block text-xs text-slate-500">Invoice {line.invoice_ref ?? "—"}{size ? ` · Size ${size}` : ""}{sku ? ` · SKU ${sku}` : ""}</span>
      </span>
    </label>
  );
}

export default async function CustomerOrderReviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ secure_order_link: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { secure_order_link: secureToken } = await params;
  const query = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data, error } = await (supabase as any).rpc("customer_pre_shipment_hold_review_v1", {
    p_secure_token: secureToken,
  });

  if (error) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-10 text-slate-950">
        <section className="mx-auto max-w-2xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-semibold uppercase tracking-[0.2em] text-rose-500">Goodcashback</p>
          <h1 className="mt-2 text-2xl font-semibold">This review link is not available</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">{error.message}</p>
        </section>
      </main>
    );
  }

  const payload = (data ?? {}) as ReviewPayload;
  const order = payload.order ?? {};
  const trackingRows = payload.tracking ?? [];
  const lineRows = payload.lines ?? [];
  const holdRows = payload.holds ?? [];
  const hasLines = lineRows.length > 0;
  const hasTracking = trackingRows.length > 0;
  const activeHolds = holdRows.filter((hold) => ["requested", "supervisor_approved"].includes(String(hold.status ?? "")));
  const pendingNarrowedLineHolds = activeHolds.filter((hold) => hold.requested_scope === "line" && hold.status === "requested" && hold.narrowed_from_hold_request_id);
  const pendingNarrowingParentIds = new Set(pendingNarrowedLineHolds.map((hold) => String(hold.narrowed_from_hold_request_id)));
  const activeHeldLineIds = new Set(
    activeHolds
      .filter((hold) => hold.requested_scope === "line" && hold.supplier_invoice_line_id)
      .map((hold) => String(hold.supplier_invoice_line_id))
  );
  const pendingHeldLineIds = new Set(
    pendingNarrowedLineHolds
      .filter((hold) => hold.supplier_invoice_line_id)
      .map((hold) => String(hold.supplier_invoice_line_id))
  );
  const heldLineRows = lineRows.filter((line) => activeHeldLineIds.has(line.id));
  const pendingLineRows = lineRows.filter((line) => pendingHeldLineIds.has(line.id));
  const approvedHeldLineRows = heldLineRows.filter((line) => !pendingHeldLineIds.has(line.id));
  const availableLineRows = lineRows.filter((line) => !activeHeldLineIds.has(line.id));
  const pendingNarrowing = pendingNarrowedLineHolds.length > 0;
  const broadHoldToNarrow = activeHolds.find((hold) => {
    if (pendingNarrowingParentIds.has(hold.id)) return false;
    if (hold.requested_scope === "order" && (hasTracking || hasLines)) return true;
    if (hold.requested_scope === "tracking" && hasLines) return true;
    return false;
  });
  const shouldPromptNarrowing = Boolean(broadHoldToNarrow);
  const narrowingScope = hasLines ? "line" : hasTracking ? "tracking" : "order";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Customer Review</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Review before shipment</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Use this page only to ask us to hold an order, package, or item before shipment. This does not edit supplier invoices, payment records, VAT, or accounting.
          </p>
          <div className="mt-5 grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm sm:grid-cols-4">
            <div><p className="text-xs uppercase tracking-wide text-slate-500">Order</p><p className="mt-1 font-semibold">{order.order_ref ?? order.id ?? "—"}</p></div>
            <div><p className="text-xs uppercase tracking-wide text-slate-500">Retailer</p><p className="mt-1 font-semibold">{order.retailer_name ?? "—"}</p></div>
            <div><p className="text-xs uppercase tracking-wide text-slate-500">Tracking refs</p><p className="mt-1 font-semibold">{trackingRows.length}</p></div>
            <div><p className="text-xs uppercase tracking-wide text-slate-500">Item lines</p><p className="mt-1 font-semibold">{lineRows.length} total · {approvedHeldLineRows.length} approved · {pendingLineRows.length} pending · {availableLineRows.length} available</p></div>
          </div>
          {query.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{query.success}</p> : null}
          {query.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-900">{query.error}</p> : null}
        </section>

        {pendingNarrowing ? (
          <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6">
            <p className="text-sm font-semibold uppercase tracking-wide text-sky-800">Waiting for supervisor</p>
            <h2 className="mt-2 text-xl font-semibold text-sky-950">Your narrowed hold selection is under review</h2>
            <p className="mt-2 text-sm leading-6 text-sky-900">
              You have selected {pendingNarrowedLineHolds.length} item line(s) to keep on hold. The original broader hold remains active until a supervisor approves this final selection. You cannot edit this selection here while it is pending.
            </p>
            {pendingLineRows.length > 0 ? (
              <div className="mt-4 grid gap-3">
                {pendingLineRows.map((line) => <LineCard key={`pending-${line.id}`} line={line} mode="pending" />)}
              </div>
            ) : null}
          </section>
        ) : null}

        {shouldPromptNarrowing && broadHoldToNarrow ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm sm:p-6">
            <p className="text-sm font-semibold uppercase tracking-wide text-amber-800">Action needed</p>
            <h2 className="mt-2 text-xl font-semibold text-amber-950">More detail is now available for your hold</h2>
            <p className="mt-2 text-sm leading-6 text-amber-900">
              Your existing {friendly(broadHoldToNarrow.requested_scope).toLowerCase()} hold is still active. Please narrow it to the available {hasLines ? "item line(s)" : "tracking/package"}. A supervisor must approve the final selection before the shipper sees the updated item-level hold.
            </p>
            <form action={narrowCustomerHoldRequestAction} className="mt-5 space-y-5">
              <input type="hidden" name="secure_token" value={secureToken} />
              <input type="hidden" name="existing_hold_request_id" value={broadHoldToNarrow.id} />
              <input type="hidden" name="requested_scope" value={narrowingScope} />

              {hasLines ? (
                <div className="space-y-3">
                  <p className="text-sm font-semibold text-amber-950">Select every item line to keep on hold</p>
                  <p className="text-xs leading-5 text-amber-900">You can select one or multiple available lines. Already-held lines are locked below so they are not submitted twice.</p>
                  {availableLineRows.length > 0 ? (
                    <div className="grid gap-3">
                      {availableLineRows.map((line) => <LineCard key={line.id} line={line} />)}
                    </div>
                  ) : (
                    <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">All available item lines already have active holds.</p>
                  )}
                  {approvedHeldLineRows.length > 0 ? (
                    <div className="mt-4 space-y-2">
                      <p className="text-xs font-semibold uppercase tracking-wide text-emerald-800">Already approved</p>
                      {approvedHeldLineRows.map((line) => <LineCard key={`held-${line.id}`} line={line} mode="held" />)}
                    </div>
                  ) : null}
                </div>
              ) : hasTracking ? (
                <div>
                  <label className="text-sm font-semibold text-amber-950">Select the package/tracking ref to keep on hold</label>
                  <select name="tracking_submission_id" required className="mt-2 w-full rounded-xl border border-amber-300 bg-white px-3 py-2 text-sm">
                    <option value="">Choose tracking/package</option>
                    {trackingRows.map((row) => (
                      <option key={row.id} value={row.id}>{row.courier_name ?? "Courier"} · {row.tracking_ref ?? row.id}</option>
                    ))}
                  </select>
                </div>
              ) : null}

              {availableLineRows.length > 0 || !hasLines ? (
                <>
                  <label className="block text-sm font-semibold text-amber-950">
                    Updated note, optional
                    <textarea name="reason" rows={3} className="mt-2 w-full rounded-xl border border-amber-300 px-3 py-2 text-sm font-normal" placeholder={broadHoldToNarrow.reason ?? "Keep the same reason or add a clearer note."} />
                  </label>

                  <button className="rounded-xl bg-amber-900 px-5 py-3 text-sm font-semibold text-white hover:bg-amber-800">
                    Submit final selection for supervisor approval
                  </button>
                </>
              ) : null}
            </form>
          </section>
        ) : null}

        {!shouldPromptNarrowing && !pendingNarrowing ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Request a hold</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              If item lines are visible, select the exact item(s). If item lines are not available yet, request a temporary package or whole-order hold and the team will narrow it later.
            </p>
            <form action={submitCustomerHoldRequestAction} className="mt-5 space-y-5">
              <input type="hidden" name="secure_token" value={secureToken} />
              <input type="hidden" name="customer_contact_label" value="" />

              {hasLines ? (
                <input type="hidden" name="requested_scope" value="line" />
              ) : hasTracking ? (
                <input type="hidden" name="requested_scope" value="tracking" />
              ) : (
                <input type="hidden" name="requested_scope" value="order" />
              )}

              {!hasTracking && !hasLines ? (
                <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
                  <p className="font-semibold">No tracking or item lines are available yet.</p>
                  <p className="mt-1">Your request will temporarily hold the whole order until the team can identify the exact item.</p>
                </div>
              ) : null}

              {hasTracking && !hasLines ? (
                <div>
                  <label className="text-sm font-semibold">Select package/tracking ref to hold</label>
                  <select name="tracking_submission_id" required className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                    <option value="">Choose tracking/package</option>
                    {trackingRows.map((row) => (
                      <option key={row.id} value={row.id}>{row.courier_name ?? "Courier"} · {row.tracking_ref ?? row.id}</option>
                    ))}
                  </select>
                </div>
              ) : null}

              {hasLines ? (
                <div className="space-y-3">
                  <p className="text-sm font-semibold">Select item(s) to hold</p>
                  {availableLineRows.length > 0 ? (
                    <div className="grid gap-3">
                      {availableLineRows.map((line) => <LineCard key={line.id} line={line} />)}
                    </div>
                  ) : (
                    <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">All item lines already have active holds.</p>
                  )}
                  {approvedHeldLineRows.length > 0 ? (
                    <div className="mt-4 space-y-2">
                      <p className="text-xs font-semibold uppercase tracking-wide text-emerald-800">Already approved</p>
                      {approvedHeldLineRows.map((line) => <LineCard key={`held-${line.id}`} line={line} mode="held" />)}
                    </div>
                  ) : null}
                </div>
              ) : null}

              {availableLineRows.length > 0 || !hasLines ? (
                <>
                  <label className="block text-sm font-semibold">
                    Reason for hold
                    <textarea name="reason" required rows={4} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="Tell us what should not be shipped or included in the final invoice." />
                  </label>

                  <button className="rounded-xl bg-slate-900 px-5 py-3 text-sm font-semibold text-white hover:bg-slate-800">
                    Submit hold request for supervisor approval
                  </button>
                </>
              ) : null}
            </form>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Hold request history</h2>
          {holdRows.length === 0 ? (
            <p className="mt-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No hold requests submitted through this link yet.</p>
          ) : (
            <div className="mt-4 space-y-3">
              {holdRows.map((hold) => (
                <article key={hold.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <p className="font-semibold">{friendly(hold.requested_scope)} hold{hold.narrowed_from_hold_request_id ? " · narrowed selection" : ""}</p>
                    <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(hold.status)}`}>{friendly(hold.status)}</span>
                  </div>
                  <p className="mt-2 text-slate-700">{hold.reason}</p>
                  {hold.supervisor_review_note ? <p className="mt-2 rounded-xl bg-white p-3 text-slate-700"><span className="font-semibold">Review note:</span> {hold.supervisor_review_note}</p> : null}
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
