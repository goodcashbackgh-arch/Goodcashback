import Link from "next/link";
import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { recordExactPackageReceiptV2Action } from "./actions";

type EntryRow = {
  tracking_line_allocation_id: string;
  supplier_invoice_line_id: string;
  item_description: string | null;
  qty_allocated: number | string;
  latest_receipt_id: string | null;
  latest_receipt_model_version: number | null;
  latest_receipt_state: string | null;
  latest_review_status: string | null;
  correction_allowed: boolean | null;
};

type DashboardRow = {
  tracking_submission_id: string | null;
  tracking_ref: string | null;
};

type SearchParams = {
  success?: string;
  error?: string;
};

function formatQty(value: number | string | null | undefined) {
  const number = Number(value ?? 0);
  if (!Number.isFinite(number)) return "0";
  return number.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function reviewLabel(value: string | null | undefined) {
  if (!value) return "No physical review yet";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export default async function ExactPhysicalReceiptPage({
  params,
  searchParams,
}: {
  params: Promise<{ tracking_submission_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { tracking_submission_id: trackingSubmissionId } = await params;
  const query = (await searchParams) ?? {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  const [{ data, error }, { data: dashboardData }] = await Promise.all([
    (supabase as any).rpc("shipper_physical_receipt_entry_v1", {
      p_tracking_submission_id: trackingSubmissionId,
    }),
    (supabase as any).rpc("shipper_package_receipt_dashboard_v1"),
  ]);

  const rows = (data ?? []) as EntryRow[];
  const dashboardRows = (dashboardData ?? []) as DashboardRow[];
  const trackingRef = dashboardRows.find(
    (row) => row.tracking_submission_id === trackingSubmissionId,
  )?.tracking_ref;
  const trackingLabel = trackingRef?.trim() || "Tracking reference unavailable";
  const first = rows[0] ?? null;
  const latestReceiptId = first?.latest_receipt_id ?? null;
  const latestReviewStatus = first?.latest_review_status ?? null;
  const correctionAllowed = Boolean(first?.correction_allowed);
  const hasPriorReceipt = Boolean(latestReceiptId);
  const submissionId = randomUUID();
  const shipper = Array.isArray((shipperUser as any).shippers)
    ? (shipperUser as any).shippers[0]
    : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper/package-receipts">← Package receipts</Link>
            <Link href={`/shipper/package-contents/${trackingSubmissionId}`}>View package contents</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Exact physical receipt</h1>
          <p className="mt-2 text-sm text-slate-600">{shipperUser.full_name} · {shipper?.name ?? "Shipper"}</p>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Record the complete package truth by supplier invoice line. Each line must balance exactly to its allocated quantity. Affected quantities require a factual note and at least one evidence file.
          </p>
          {query.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{query.success}</p> : null}
          {query.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{query.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        {rows.length === 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-950 shadow-sm sm:p-6">
            No exact positive allocations are available for this package, or this package is not visible to your shipper account. No receipt can be submitted.
          </section>
        ) : (
          <form action={recordExactPackageReceiptV2Action} className="space-y-6">
            <input type="hidden" name="tracking_submission_id" value={trackingSubmissionId} />
            <input type="hidden" name="receipt_submission_id" value={submissionId} />
            {hasPriorReceipt && correctionAllowed ? <input type="hidden" name="correction_of_receipt_id" value={latestReceiptId ?? ""} /> : null}

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">Package allocation lines</h2>
                  <p className="mt-1 text-sm text-slate-600">Tracking package {trackingLabel}</p>
                </div>
                <span className="w-fit rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">{reviewLabel(latestReviewStatus)}</span>
              </div>

              <div className="mt-5 space-y-4">
                {rows.map((row, index) => {
                  const allocated = formatQty(row.qty_allocated);
                  return (
                    <article key={row.tracking_line_allocation_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                      <input type="hidden" name="allocation_id" value={row.tracking_line_allocation_id} />
                      <input type="hidden" name={`supplier_invoice_line_id_${row.tracking_line_allocation_id}`} value={row.supplier_invoice_line_id} />
                      <input type="hidden" name={`allocated_qty_${row.tracking_line_allocation_id}`} value={allocated} />

                      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                        <div>
                          <p className="text-xs uppercase tracking-wide text-slate-500">Line {index + 1}</p>
                          <h3 className="mt-1 font-semibold">{row.item_description ?? "Unlabelled supplier invoice line"}</h3>
                        </div>
                        <span className="rounded-full bg-white px-3 py-1 text-sm font-semibold text-slate-900">Allocated {allocated}</span>
                      </div>

                      <div className="mt-4 grid gap-3 md:grid-cols-2">
                        <label className="space-y-1 text-sm">
                          <span className="text-xs uppercase tracking-wide text-slate-500">Clean quantity</span>
                          <input type="number" name={`clean_qty_${row.tracking_line_allocation_id}`} defaultValue={allocated} min="0" step="0.001" required className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                        </label>
                        <label className="space-y-1 text-sm">
                          <span className="text-xs uppercase tracking-wide text-slate-500">Affected quantity</span>
                          <input type="number" name={`affected_qty_${row.tracking_line_allocation_id}`} defaultValue="0" min="0" step="0.001" required className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                        </label>
                        <label className="space-y-1 text-sm">
                          <span className="text-xs uppercase tracking-wide text-slate-500">Affected disposition</span>
                          <select name={`affected_type_${row.tracking_line_allocation_id}`} defaultValue="" className="w-full rounded-xl border border-slate-300 px-3 py-2">
                            <option value="">Not applicable — clean</option>
                            <option value="damaged">Damaged</option>
                            <option value="missing">Missing</option>
                            <option value="wrong">Wrong item</option>
                            <option value="held">Held / query</option>
                          </select>
                        </label>
                        <label className="space-y-1 text-sm">
                          <span className="text-xs uppercase tracking-wide text-slate-500">Condition note for affected quantity</span>
                          <input name={`condition_note_${row.tracking_line_allocation_id}`} className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Required only when affected quantity is above zero" />
                        </label>
                      </div>
                      <p className="mt-3 text-xs text-slate-500">Clean plus affected must equal exactly {allocated}. Choose an affected disposition only when affected quantity is above zero.</p>
                    </article>
                  );
                })}
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Evidence and correction</h2>
              <div className="mt-4 grid gap-4 md:grid-cols-2">
                <label className="space-y-1 text-sm md:col-span-2">
                  <span className="text-xs uppercase tracking-wide text-slate-500">Receipt evidence files</span>
                  <input name="receipt_evidence_files" type="file" multiple accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className="w-full rounded-xl border border-slate-300 px-3 py-2" />
                  <span className="block text-xs text-slate-500">Required when any line has affected quantity. Files are stored under the governed shipper receipt path.</span>
                </label>

                {hasPriorReceipt ? (
                  correctionAllowed ? (
                    <label className="space-y-1 text-sm md:col-span-2">
                      <span className="text-xs uppercase tracking-wide text-slate-500">Correction reason</span>
                      <textarea name="correction_reason" rows={3} required className="w-full rounded-xl border border-slate-300 px-3 py-2" placeholder="Explain the factual correction to the latest receipt" />
                      <span className="block text-xs text-slate-500">This submission will be a complete replacement snapshot of receipt {latestReceiptId}.</span>
                    </label>
                  ) : (
                    <p className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900 md:col-span-2">
                      Correction is blocked because the latest physical review is terminal or retailer-linked. Use controlled staff remediation rather than submitting another receipt.
                    </p>
                  )
                ) : null}
              </div>
            </section>

            <section className="rounded-3xl border border-slate-900 bg-slate-900 p-5 text-white shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Final submission</h2>
              <p className="mt-2 text-sm text-slate-300">This writes one immutable finalised receipt snapshot. Review every line before submitting.</p>
              <button type="submit" disabled={hasPriorReceipt && !correctionAllowed} className="mt-4 rounded-xl bg-white px-4 py-2 text-sm font-semibold text-slate-950 disabled:cursor-not-allowed disabled:bg-slate-500 disabled:text-slate-200">
                {hasPriorReceipt ? "Submit corrected exact receipt" : "Submit exact physical receipt"}
              </button>
            </section>
          </form>
        )}
      </div>
    </main>
  );
}
