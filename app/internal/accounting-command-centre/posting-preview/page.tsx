import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

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

function short(value: unknown, max = 64) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
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

function Pill({ label, value }: { label: string; value: unknown }) {
  return <span className={`inline-flex rounded-full border px-3 py-1 text-xs font-bold ${toneClass(statusTone(value))}`}>{label}: {pretty(value)}</span>;
}

export default async function PostingPreviewIndexPage() {
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
  if (!canAccess) redirect("/internal/accounting-command-centre");

  const { data, error } = await (supabase as any).rpc("internal_sage_posting_snapshot_queue_v1");
  const rows = ((data ?? []) as Row[]);
  const readyRows = rows.filter((row) => text(row.posting_gate_status) === "ready_to_post");
  const blockedRows = rows.filter((row) => text(row.posting_gate_status) === "blocked_before_posting");
  const totalReady = readyRows.reduce((sum, row) => sum + num(row.amount_gbp), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/accounting-command-centre">← Accounting command centre</Link>
            <Link href="/internal/sage-ready">Live Sage queue</Link>
            <Link href="/internal/sage-mapping">Mappings</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Frozen posting previews</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Final Sage posting preview index</h1>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            Open each frozen snapshot to inspect the exact frozen payload, mapping snapshot, line payload, approval audit and idempotency key before any future Sage posting action is enabled.
          </p>
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Snapshot queue unavailable: {error.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-900 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Ready to post</p>
            <p className="mt-2 text-3xl font-extrabold">{readyRows.length}</p>
            <p className="mt-1 text-sm">{gbp(totalReady)} ready value</p>
          </div>
          <div className="rounded-3xl border border-rose-200 bg-rose-50 p-4 text-rose-900 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Blocked</p>
            <p className="mt-2 text-3xl font-extrabold">{blockedRows.length}</p>
            <p className="mt-1 text-sm">Must not be posted</p>
          </div>
          <div className="rounded-3xl border border-violet-200 bg-violet-50 p-4 text-violet-900 shadow-sm">
            <p className="text-xs font-bold uppercase tracking-wide opacity-70">Total snapshots</p>
            <p className="mt-2 text-3xl font-extrabold">{rows.length}</p>
            <p className="mt-1 text-sm">Frozen approval records</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-5 py-4">
            <h2 className="text-xl font-semibold">Frozen snapshots</h2>
            <p className="mt-1 text-sm text-slate-500">One row per Sage-bound frozen document.</p>
          </div>

          {rows.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No frozen posting snapshots found.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {rows.map((row) => (
                <article key={text(row.snapshot_id)} className="p-5">
                  <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="text-lg font-extrabold text-slate-950">{text(row.order_ref) || text(row.reference_text) || short(row.snapshot_id)}</h3>
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
                    <Pill label="Approval" value={row.approval_status} />
                    <Pill label="Revalidation" value={row.revalidation_status} />
                    <Pill label="Posting" value={row.sage_posting_status} />
                  </div>

                  <div className="mt-4 flex flex-wrap gap-2">
                    <Link href={`/internal/accounting-command-centre/snapshots/${text(row.snapshot_id)}`} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">
                      Open final posting preview
                    </Link>
                    <Link href="/internal/accounting-command-centre" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-bold text-slate-800 hover:bg-slate-50">
                      Back to cockpit
                    </Link>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900">
          <h2 className="font-bold">Control rule</h2>
          <p className="mt-2">This is still a preview layer. It does not call Sage, does not mark posted, and does not override the frozen payload. The future posting action must use the snapshot id and idempotency key.</p>
        </section>
      </div>
    </main>
  );
}
