import Link from "next/link";
import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import ExactPhysicalReceiptForm from "./ExactPhysicalReceiptForm";

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
          <p className="mt-4 w-fit rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">{reviewLabel(latestReviewStatus)}</p>
          {query.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{query.success}</p> : null}
          {query.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{query.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}</p> : null}
        </section>

        {rows.length === 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-950 shadow-sm sm:p-6">
            No exact positive allocations are available for this package, or this package is not visible to your shipper account. No receipt can be submitted.
          </section>
        ) : (
          <ExactPhysicalReceiptForm
            rows={rows.map((row) => ({
              tracking_line_allocation_id: row.tracking_line_allocation_id,
              supplier_invoice_line_id: row.supplier_invoice_line_id,
              item_description: row.item_description,
              qty_allocated: row.qty_allocated,
            }))}
            trackingSubmissionId={trackingSubmissionId}
            trackingLabel={trackingLabel}
            latestReceiptId={latestReceiptId}
            correctionAllowed={correctionAllowed}
            submissionId={submissionId}
          />
        )}
      </div>
    </main>
  );
}
