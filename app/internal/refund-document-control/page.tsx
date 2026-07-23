import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParams = { success?: string; error?: string };

type Submission = {
  id: string;
  dispute_id: string;
  document_mode: string;
  credit_note_ref: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  variance_abs_gbp: number | null;
  amount_balance_status: string | null;
  evidence_control_status: string | null;
  supplier_readiness_route: string | null;
  supplier_approval_status: string | null;
  supervisor_review_status: string | null;
  ocr_status: string | null;
  match_status: string | null;
  supplier_control_status: string | null;
  submitted_at: string | null;
};

type DisputeRow = {
  id: string;
  order_id: string;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | null;
};

type OrderLite = {
  id: string;
  order_ref: string | null;
  retailers: { name: string | null } | { name: string | null }[] | null;
  importers: { company_name: string | null } | { company_name: string | null }[] | null;
};

function first<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function statusLabel(value: string | null | undefined) {
  return String(value ?? "—").replaceAll("_", " ");
}

function badgeClass(value: string | null | undefined) {
  const status = String(value ?? "");
  if (["approved_current", "matched_ready_to_release", "released_to_supplier_control"].includes(status)) return "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200";
  if (["needs_operator_review", "needs_supervisor_review", "pending_ocr", "pending_review"].includes(status)) return "bg-amber-50 text-amber-800 ring-1 ring-amber-200";
  if (["blocked", "failed", "rejected"].includes(status)) return "bg-rose-50 text-rose-800 ring-1 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-1 ring-slate-200";
}

export default async function RefundDocumentControlQueuePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
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
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: submissionsRaw, error } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, document_mode, credit_note_ref, expected_credit_note_total_gbp, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, amount_balance_status, evidence_control_status, supplier_readiness_route, supplier_approval_status, supervisor_review_status, ocr_status, match_status, supplier_control_status, submitted_at")
    .neq("supplier_approval_status", "approved_current")
    .order("submitted_at", { ascending: false })
    .limit(100);

  const submissions = (submissionsRaw ?? []) as Submission[];
  const disputeIds = [...new Set(submissions.map((row) => row.dispute_id).filter(Boolean))];

  const { data: disputesRaw } = disputeIds.length
    ? await supabase
        .from("disputes")
        .select("id, order_id, desired_outcome, status, amount_impact_gbp")
        .in("id", disputeIds)
    : { data: [] };

  const disputes = (disputesRaw ?? []) as DisputeRow[];
  const orderIds = [...new Set(disputes.map((row) => row.order_id).filter(Boolean))];

  const { data: ordersRaw } = orderIds.length
    ? await supabase
        .from("orders")
        .select("id, order_ref, retailers(name), importers(company_name)")
        .in("id", orderIds)
    : { data: [] };

  const disputeById = new Map(disputes.map((row) => [row.id, row]));
  const orderById = new Map(((ordersRaw ?? []) as unknown as OrderLite[]).map((row) => [row.id, row]));

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/supplier-draft-ready" className="text-sm font-semibold text-sky-600">← Back to supplier draft ready</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Refund document control</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Supplier credit / refund document queue</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This queue is for credit notes, refund-proof-without-credit-note, and no-document refund evidence. Open the detail page to release lines, code net/VAT/gross, add manual adjustments, and approve current.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        {error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-800">Failed to load refund document queue: {error.message}</section> : null}

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Open submissions</p><p className="mt-2 text-3xl font-semibold">{submissions.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Credit notes</p><p className="mt-2 text-3xl font-semibold">{submissions.filter((row) => row.document_mode === "credit_note").length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">No credit note</p><p className="mt-2 text-3xl font-semibold">{submissions.filter((row) => row.document_mode === "refund_proof_no_credit_note").length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">No document</p><p className="mt-2 text-3xl font-semibold">{submissions.filter((row) => row.document_mode === "no_document").length}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold">Open refund document submissions</h2>
          <p className="mt-2 text-sm text-slate-600">On smaller screens, swipe left or right across the table to see every column and action.</p>
          <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="min-w-[1100px] text-left text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="p-3">Order</th>
                  <th className="p-3">Importer / retailer</th>
                  <th className="p-3">Mode</th>
                  <th className="p-3">Ref</th>
                  <th className="p-3">Amount</th>
                  <th className="p-3">Match</th>
                  <th className="p-3">Control</th>
                  <th className="p-3">Action</th>
                </tr>
              </thead>
              <tbody>
                {submissions.map((submission) => {
                  const dispute = disputeById.get(submission.dispute_id);
                  const order = dispute ? orderById.get(dispute.order_id) : null;
                  const amount = submission.expected_credit_note_total_gbp ?? submission.captured_refund_amount_abs_gbp ?? submission.expected_exception_amount_abs_gbp ?? dispute?.amount_impact_gbp ?? 0;
                  return (
                    <tr key={submission.id} className="border-t align-top">
                      <td className="p-3 font-semibold">{order?.order_ref ?? dispute?.order_id ?? "—"}</td>
                      <td className="p-3"><div>{first(order?.importers)?.company_name ?? "—"}</div><div className="text-xs text-slate-500">{first(order?.retailers)?.name ?? "—"}</div></td>
                      <td className="p-3 capitalize">{statusLabel(submission.document_mode)}</td>
                      <td className="p-3">{submission.credit_note_ref ?? "—"}</td>
                      <td className="p-3 font-semibold">{gbp(amount)}</td>
                      <td className="p-3"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(submission.match_status)}`}>{statusLabel(submission.match_status)}</span></td>
                      <td className="p-3"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(submission.supplier_control_status)}`}>{statusLabel(submission.supplier_control_status)}</span></td>
                      <td className="p-3">
                        <div className="flex min-w-[170px] flex-col gap-2">
                          <Link href={`/internal/refund-document-control/${submission.id}`} className="rounded-lg bg-slate-900 px-3 py-2 text-center text-xs font-semibold text-white">Open control</Link>
                          <Link href={`/internal/refund-document-control/${submission.id}/request-resubmission`} className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-center text-xs font-semibold text-amber-900">Request resubmission</Link>
                        </div>
                      </td>
                    </tr>
                  );
                })}
                {submissions.length === 0 ? (
                  <tr><td colSpan={8} className="p-6 text-center text-sm text-slate-500">No open refund document submissions.</td></tr>
                ) : null}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
