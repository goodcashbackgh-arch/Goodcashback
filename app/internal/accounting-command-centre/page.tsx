import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { freezeSelectedCustomerSalesRowsAction } from "./actions";

type Row = Record<string, unknown>;
type Tone = "complete" | "progress" | "action" | "blocked" | "review" | "muted";

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
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

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 70) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "progress") return "border-sky-200 bg-sky-50 text-sky-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function statusTone(status: unknown): Tone {
  const raw = text(status);
  if (["ready_to_post", "ok_to_post", "posted", "sage_confirmation_recorded", "ready_for_sage_posting_preview"].includes(raw)) return "complete";
  if (["requires_revalidation", "not_revalidated", "not_posted", "frozen_pending_posting"].includes(raw)) return "action";
  if (["blocked_before_posting", "stale_reapproval_required", "blocked_source_not_ready", "posting_failed"].includes(raw)) return "blocked";
  if (["warning_only", "approved_frozen"].includes(raw)) return "review";
  return "muted";
}

function accessFromPermissions(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Row;
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

function SnapshotStatusPill({ label, value }: { label: string; value: unknown }) {
  return (
    <span className={`inline-flex rounded-full border px-2.5 py-1 text-xs font-bold ${toneClass(statusTone(value))}`}>
      {label}: {pretty(value)}
    </span>
  );
}

function FoundationCard({ title, value, detail, tone, href }: { title: string; value: string; detail: string; tone: Tone; href?: string }) {
  const content = (
    <div className={`h-full rounded-3xl border p-4 shadow-sm ${toneClass(tone)}`}>
      <p className="text-xs font-bold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-2 text-2xl font-extrabold">{value}</p>
      <p className="mt-1 text-xs leading-5 opacity-90">{detail}</p>
    </div>
  );

  return href ? <Link href={href}>{content}</Link> : content;
}

export default async function AccountingCommandCentrePage({ searchParams }: { searchParams?: Promise<{ q?: string; lane?: string; status?: string; success?: string; error?: string }> }) {
  const qp = searchParams ? await searchParams : {};
  const search = (qp.q ?? "").trim().toLowerCase();
  const laneFilter = qp.lane ?? "all";
  const statusFilter = qp.status ?? "all";

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);

  if (!canAccess) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl space-y-5">
          <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
            <h1 className="mt-5 text-3xl font-bold tracking-tight">Admin Accounting Command Centre</h1>
            <p className="mt-3 text-sm leading-6 text-slate-600">This page is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
          </section>
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
            <h2 className="font-bold">Access required</h2>
            <p className="mt-2">For testing, keep the user as supervisor and grant the narrow <code>accounting_admin_testing</code> flag in <code>staff.permissions_json</code>. Do not change their primary role away from supervisor just to access this page.</p>
          </section>
        </div>
      </main>
    );
  }

  const [snapshotResult, readyQueueResult, mappingResult] = await Promise.all([
    (supabase as any).rpc("internal_sage_posting_snapshot_queue_v1"),
    (supabase as any).rpc("internal_ready_for_sage_queue_v2"),
    (supabase as any).rpc("internal_sage_mapping_control_v1"),
  ]);

  const snapshots = ((snapshotResult.data ?? []) as Row[]);
  const readyRows = ((readyQueueResult.data ?? []) as Row[]);
  const mappingRows = ((mappingResult.data ?? []) as Row[]);

  const filteredSnapshots = snapshots.filter((row) => {
    if (laneFilter !== "all" && text(row.document_lane) !== laneFilter) return false;
    if (statusFilter !== "all" && text(row.posting_gate_status) !== statusFilter) return false;
    if (!search) return true;
    return [
      row.order_ref,
      row.reference_text,
      row.counterparty_name,
      row.document_lane,
      row.document_type,
      row.batch_ref,
      row.idempotency_key,
    ].map(text).join(" ").toLowerCase().includes(search);
  });

  const liveReadyNotFrozen = readyRows.filter((row) => {
    if (!text(row.readiness_status).startsWith("ready")) return false;
    const sourceId = text(row.source_id);
    return !snapshots.some((snapshot) => text(snapshot.source_id) === sourceId && text(snapshot.approval_status) === "approved_frozen" && text(snapshot.sage_posting_status) !== "posted");
  });
  const customerSalesReadyNotFrozen = liveReadyNotFrozen.filter((row) => text(row.document_lane) === "customer_sales" && text(row.source_table) === "sales_invoices");
  const otherReadyNotFrozen = liveReadyNotFrozen.filter((row) => !(text(row.document_lane) === "customer_sales" && text(row.source_table) === "sales_invoices"));

  const readyToPost = snapshots.filter((row) => text(row.posting_gate_status) === "ready_to_post").length;
  const requiresRevalidation = snapshots.filter((row) => text(row.posting_gate_status) === "requires_revalidation").length;
  const blocked = snapshots.filter((row) => text(row.posting_gate_status) === "blocked_before_posting").length;
  const posted = snapshots.filter((row) => text(row.posting_gate_status) === "posted" || text(row.sage_posting_status) === "posted").length;
  const mappingMissing = mappingRows.filter((row) => text(row.mapping_status) !== "configured").length;

  const totalFrozenValue = snapshots
    .filter((row) => text(row.approval_status) === "approved_frozen" && text(row.sage_posting_status) !== "posted")
    .reduce((sum, row) => sum + num(row.amount_gbp), 0);

  const lanes = Array.from(new Set(snapshots.map((row) => text(row.document_lane)).filter(Boolean))).sort();
  const statuses = Array.from(new Set(snapshots.map((row) => text(row.posting_gate_status)).filter(Boolean))).sort();
  const errors = [
    snapshotResult.error ? `Snapshot queue: ${snapshotResult.error.message}` : "",
    readyQueueResult.error ? `Ready queue: ${readyQueueResult.error.message}` : "",
    mappingResult.error ? `Mappings: ${mappingResult.error.message}` : "",
  ].filter(Boolean);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Admin Accounting</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Accounting Command Centre</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
                Accounting cockpit for Sage-bound documents: live payload readiness, freeze approval, frozen snapshots, revalidation status and posting gate. This is the admin view; the supervisor command centre remains the order-to-clean-delivery view.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
          {qp.success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{qp.error}</p> : null}
          {errors.length > 0 ? (
            <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              <p className="font-bold">Some accounting lanes could not be read</p>
              <ul className="mt-2 list-disc space-y-1 pl-5">{errors.map((error) => <li key={error}>{error}</li>)}</ul>
            </div>
          ) : null}
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-6">
          <FoundationCard title="Ready to post" value={String(readyToPost)} detail="Frozen and revalidated snapshots" tone={readyToPost > 0 ? "complete" : "muted"} />
          <FoundationCard title="Requires revalidation" value={String(requiresRevalidation)} detail="Frozen but not checked since approval" tone={requiresRevalidation > 0 ? "action" : "complete"} />
          <FoundationCard title="Blocked" value={String(blocked)} detail="Mapping/source/payload changed or failed gate" tone={blocked > 0 ? "blocked" : "complete"} />
          <FoundationCard title="Posted" value={String(posted)} detail="Sage posting confirmed/recorded" tone={posted > 0 ? "complete" : "muted"} />
          <FoundationCard title="Live ready not frozen" value={String(liveReadyNotFrozen.length)} detail={`${customerSalesReadyNotFrozen.length} customer sales freezeable; ${otherReadyNotFrozen.length} other lane(s)`} tone={liveReadyNotFrozen.length > 0 ? "action" : "complete"} />
          <FoundationCard title="Frozen value" value={gbp(totalFrozenValue)} detail={mappingMissing > 0 ? `${mappingMissing} mapping issue(s)` : "Unposted approved snapshots"} tone={mappingMissing > 0 ? "blocked" : "review"} href="/internal/sage-mapping" />
        </section>

        {liveReadyNotFrozen.length > 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
            <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
              <div>
                <h2 className="text-xl font-bold">Live ready rows not frozen yet</h2>
                <p className="mt-2">Freeze converts a ready live payload into an approved posting snapshot. Customer sales rows are freezeable here now; other lanes are listed but remain blocked from posting until their freeze resolver is added.</p>
              </div>
              <Link href="/internal/sage-ready" className="w-fit rounded-xl border border-amber-300 bg-white px-4 py-2 text-sm font-bold text-amber-900">Open live Sage queue</Link>
            </div>

            <form action={freezeSelectedCustomerSalesRowsAction} className="mt-4 space-y-3">
              {liveReadyNotFrozen.map((row) => {
                const isCustomerSales = text(row.document_lane) === "customer_sales" && text(row.source_table) === "sales_invoices";
                return (
                  <label key={text(row.queue_row_id) || text(row.source_id)} className={`block rounded-2xl border bg-white p-4 ${isCustomerSales ? "border-amber-300" : "border-slate-200 opacity-80"}`}>
                    <div className="flex items-start gap-3">
                      <input
                        type="checkbox"
                        name="sales_invoice_id"
                        value={text(row.source_id)}
                        defaultChecked={isCustomerSales}
                        disabled={!isCustomerSales}
                        className="mt-1 h-5 w-5 rounded border-slate-300"
                      />
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="font-extrabold text-slate-950">{text(row.order_ref) || text(row.reference_text) || text(row.queue_row_id)}</p>
                          <span className="rounded-full bg-slate-100 px-2 py-1 text-xs font-bold text-slate-700">{pretty(row.document_lane)}</span>
                          <span className="rounded-full bg-slate-100 px-2 py-1 text-xs font-bold text-slate-700">{pretty(row.document_type)}</span>
                        </div>
                        <p className="mt-1 text-sm text-slate-700">{text(row.counterparty_name) || "Counterparty"} · {gbp(row.amount_gbp)} · {pretty(row.readiness_status)}</p>
                        <p className="mt-1 text-xs text-slate-500">Source {text(row.source_table)} · {short(row.source_id, 42)}</p>
                        {!isCustomerSales ? <p className="mt-2 text-xs font-bold text-amber-800">Visible only: this lane needs its own freeze resolver before posting can be enabled.</p> : null}
                      </div>
                    </div>
                  </label>
                );
              })}
              <button
                type="submit"
                disabled={customerSalesReadyNotFrozen.length === 0}
                className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-bold text-white shadow-sm hover:bg-amber-800 disabled:cursor-not-allowed disabled:bg-slate-300"
              >
                Freeze selected customer sales rows
              </button>
            </form>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5">
          <form action="/internal/accounting-command-centre" className="grid gap-3 lg:grid-cols-[1fr_auto_auto_auto] lg:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Search documents
              <input name="q" defaultValue={qp.q ?? ""} placeholder="Order ref, counterparty, batch, idempotency key" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Lane
              <select name="lane" defaultValue={laneFilter} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All lanes</option>
                {lanes.map((lane) => <option key={lane} value={lane}>{pretty(lane)}</option>)}
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Posting gate
              <select name="status" defaultValue={statusFilter} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All statuses</option>
                {statuses.map((status) => <option key={status} value={status}>{pretty(status)}</option>)}
              </select>
            </label>
            <div className="flex gap-2">
              <button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply</button>
              <Link href="/internal/accounting-command-centre" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Reset</Link>
            </div>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-100 px-5 py-4">
            <div>
              <h2 className="text-xl font-semibold">Frozen posting snapshots</h2>
              <p className="mt-1 text-sm text-slate-500">Showing {filteredSnapshots.length} of {snapshots.length} snapshot row(s)</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link href="/internal/sage-ready" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Open live Sage queue</Link>
              <Link href="/internal/sage-mapping" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Open mappings</Link>
            </div>
          </div>

          {filteredSnapshots.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No frozen posting snapshots match this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {filteredSnapshots.map((row) => (
                <article key={text(row.snapshot_id)} className="p-5">
                  <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="text-lg font-extrabold text-slate-950">{text(row.order_ref) || text(row.reference_text) || text(row.snapshot_id)}</h3>
                        <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">{pretty(row.document_lane)}</span>
                        <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">{pretty(row.document_type)}</span>
                      </div>
                      <p className="mt-1 text-sm text-slate-600">{text(row.counterparty_name) || "Counterparty"} · {gbp(row.amount_gbp)} · Ref {text(row.reference_text) || "—"}</p>
                      <p className="mt-1 text-xs text-slate-500">Batch {text(row.batch_ref)} · Idempotency {short(row.idempotency_key, 36)}</p>
                    </div>
                    <div className={`rounded-2xl border p-3 ${toneClass(statusTone(row.posting_gate_status))}`}>
                      <p className="text-xs font-bold uppercase tracking-wide opacity-70">Posting gate</p>
                      <p className="mt-1 text-lg font-extrabold">{pretty(row.posting_gate_status)}</p>
                      <p className="mt-1 text-xs leading-5 opacity-90">{text(row.posting_gate_blocker) || "No blocker"}</p>
                    </div>
                  </div>

                  <div className="mt-4 flex flex-wrap gap-2">
                    <SnapshotStatusPill label="Approval" value={row.approval_status} />
                    <SnapshotStatusPill label="Revalidation" value={row.revalidation_status} />
                    <SnapshotStatusPill label="Posting" value={row.sage_posting_status} />
                    {text(row.sage_invoice_id) ? <SnapshotStatusPill label="Sage ID" value={row.sage_invoice_id} /> : null}
                  </div>

                  <div className="mt-4 grid gap-3 lg:grid-cols-3">
                    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm">
                      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Approved</p>
                      <p className="mt-1 font-semibold text-slate-900">{text(row.approved_at) ? text(row.approved_at).slice(0, 19).replace("T", " ") : "—"}</p>
                    </div>
                    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm">
                      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Revalidated</p>
                      <p className="mt-1 font-semibold text-slate-900">{text(row.revalidated_at) ? text(row.revalidated_at).slice(0, 19).replace("T", " ") : "Not revalidated"}</p>
                    </div>
                    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm">
                      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Next action</p>
                      <p className="mt-1 font-semibold text-slate-900">
                        {text(row.posting_gate_status) === "ready_to_post" ? "Post to Sage later" : text(row.posting_gate_status) === "requires_revalidation" ? "Revalidate before posting" : text(row.posting_gate_status) === "blocked_before_posting" ? "Resolve blocker / re-approve" : pretty(row.posting_gate_status)}
                      </p>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900">
          <h2 className="font-bold">Control rule</h2>
          <p className="mt-2">This page freezes ready customer sales payloads into posting snapshots and shows posting gates. It does not call Sage. Shipper AP freeze and actual posting remain separate next controls.</p>
        </section>
      </div>
    </main>
  );
}
