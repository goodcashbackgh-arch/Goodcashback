import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveSageOnlyPurchaseBucketsAction } from "./actions";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}
function num(value: unknown): number { const parsed = Number(text(value).replace(/,/g, "")); return Number.isFinite(parsed) ? parsed : 0; }
function obj(value: unknown): Row { return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {}; }
function gbp(value: unknown): string { return money.format(num(value)); }
function pretty(value: unknown): string { const raw = text(value); return raw ? raw.replaceAll("_", " ") : "—"; }
function cut(value: unknown, max = 72): string { const raw = text(value); return raw ? (raw.length > max ? `${raw.slice(0, max - 1)}…` : raw) : "—"; }
function purchaseReview(snapshot: Row): Row { return obj(obj(snapshot.source_summary).purchase_vat_line_review); }
function bucketRows(review: Row): Row[] { return Object.entries(obj(review.buckets)).map(([bucket, value]) => ({ bucket, ...obj(value) })); }
function sampleRows(review: Row): Row[] { return Array.isArray(review.review_sample) ? review.review_sample as Row[] : []; }

function sourceForBucket(bucket: string, review: Row): Row[] {
  return sampleRows(review).filter((row) => text(row.bucket) === bucket).slice(0, 8);
}

export default async function SageOnlyPurchaseApprovalPage({ params, searchParams }: any) {
  const routeParams = params ? await params : {};
  const queryParams = searchParams ? await searchParams : {};
  const runId = text(routeParams?.return_run_id);
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("id, role_type, full_name").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff || text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const [{ data: run }, { data: snapshots }] = await Promise.all([
    (supabase as any).from("vat_return_runs").select("id, run_ref, return_period_label, status, expected_box4_gbp, expected_box7_gbp, locked_at").eq("id", runId).maybeSingle(),
    (supabase as any).from("vat_return_sage_reconstruction_snapshots").select("id, created_at, source_basis, box4_gbp, box7_gbp, source_summary").eq("vat_return_run_id", runId).order("created_at", { ascending: false }).limit(20),
  ]);

  if (!run) redirect("/internal/accounting-vat");

  const usableSnapshot = ((snapshots ?? []) as Row[]).find((row) => text(purchaseReview(row).version));
  const review = usableSnapshot ? purchaseReview(usableSnapshot) : {};
  const buckets = bucketRows(review).filter((row) => !text(row.bucket).startsWith("platform_controlled"));
  const error = text(queryParams?.vatError);

  const sageOnlyBox4 = buckets.reduce((sum, row) => sum + num(row.box4), 0);
  const sageOnlyBox7 = buckets.reduce((sum, row) => sum + num(row.box7), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-5xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-vat/returns/${runId}?tab=purchases`} className="text-sm font-semibold text-sky-600">← Back to Box 4 / Box 7 purchases</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Sage-only purchase approval</p>
          <h1 className="mt-3 text-3xl font-semibold tracking-tight">{cut((run as Row).return_period_label || (run as Row).run_ref || runId)}</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">Approve reviewed Sage-only purchase buckets into the platform VAT return. This creates platform VAT source lines only. It does not post a Sage journal.</p>
          {error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{error}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase text-slate-500">Current platform Box 4</p><p className="mt-2 text-2xl font-extrabold">{gbp((run as Row).expected_box4_gbp)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase text-slate-500">Current platform Box 7</p><p className="mt-2 text-2xl font-extrabold">{gbp((run as Row).expected_box7_gbp)}</p></div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sky-900 shadow-sm"><p className="text-xs font-bold uppercase">Selectable Sage-only total</p><p className="mt-2 text-sm font-bold">Box 4 {gbp(sageOnlyBox4)} / Box 7 {gbp(sageOnlyBox7)}</p></div>
        </section>

        {!usableSnapshot ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm font-semibold text-amber-900">Run Sage reconstruction first. No purchase review snapshot is available.</section>
        ) : buckets.length === 0 ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm font-semibold text-emerald-900">No visible Sage-only purchase buckets to approve.</section>
        ) : (
          <form action={approveSageOnlyPurchaseBucketsAction} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <input type="hidden" name="vat_return_run_id" value={runId} />
            <input type="hidden" name="sage_snapshot_id" value={text(usableSnapshot.id)} />
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold tracking-tight">Select reviewed Sage-only buckets</h2>
                <p className="mt-1 text-sm text-slate-600">Approve only buckets you accept into the platform VAT return.</p>
              </div>
              <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Approve selected into platform VAT return</button>
            </div>
            <div className="mt-5 grid gap-3">
              {buckets.map((bucket) => {
                const key = text(bucket.bucket);
                const samples = sourceForBucket(key, review);
                return (
                  <label key={key} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                    <div className="flex items-start gap-3">
                      <input type="checkbox" name="bucket_keys" value={key} className="mt-1 h-4 w-4" />
                      <div className="flex-1">
                        <div className="flex flex-wrap items-center justify-between gap-3">
                          <p className="font-bold text-slate-950">{pretty(key)}</p>
                          <p className="font-semibold text-slate-700">{text(bucket.count) || "0"} line(s) · Box 4 {gbp(bucket.box4)} · Box 7 {gbp(bucket.box7)}</p>
                        </div>
                        {samples.length ? (
                          <div className="mt-3 grid gap-2">
                            {samples.map((row, index) => <p key={`${key}-${index}`} className="rounded-xl bg-white px-3 py-2 text-xs text-slate-700">{cut(row.document_label, 42)} · {cut(row.ledger_account, 36)} · {cut(row.tax_rate, 24)} · Net {gbp(row.net_amount)} · VAT {gbp(row.vat_amount)}</p>)}
                          </div>
                        ) : null}
                      </div>
                    </div>
                  </label>
                );
              })}
            </div>
          </form>
        )}
      </div>
    </main>
  );
}
