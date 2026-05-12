import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { reviewShipperReturnTaskConfirmationAction } from "./actions";

type AffectedLine = {
  supplier_invoice_line_id?: string | null;
  description?: string | null;
  qty?: number | string | null;
  amount_gbp?: number | string | null;
  intended_remedy?: string | null;
  line_status?: string | null;
};

type ReviewRow = {
  confirmation_id: string;
  return_tracking_submission_id: string;
  dispute_id: string;
  order_id: string;
  order_ref: string | null;
  shipper_name: string | null;
  importer_name: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  operator_return_instructions_file_url: string | null;
  return_label_file_url: string | null;
  operator_tracking_evidence_url: string | null;
  operator_note: string | null;
  affected_lines: AffectedLine[] | null;
  outcome: string | null;
  proof_url: string | null;
  shipper_note: string | null;
  submitted_at: string | null;
  review_status: string | null;
  reviewed_at: string | null;
  review_notes: string | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function money(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number.isFinite(parsed) ? parsed : 0);
}

function statusClass(status: string | null | undefined) {
  if (status === "pending_review") return "bg-sky-100 text-sky-900";
  if (status === "accepted") return "bg-emerald-100 text-emerald-900";
  if (status === "hold") return "bg-orange-100 text-orange-900";
  if (status === "rejected") return "bg-rose-100 text-rose-900";
  return "bg-slate-100 text-slate-700";
}

export default async function InternalShipperReturnTasksPage({
  searchParams,
}: {
  searchParams?: Promise<{ include_closed?: string; success?: string; error?: string }>;
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

  const { data, error } = await (supabase as any).rpc("internal_shipper_return_task_confirmations_v1", {
    p_include_closed: includeClosed,
  });

  const rows = (data ?? []) as ReviewRow[];
  const pendingRows = rows.filter((row) => row.review_status === "pending_review");
  const acceptedRows = rows.filter((row) => row.review_status === "accepted");
  const queryRows = rows.filter((row) => ["hold", "rejected"].includes(String(row.review_status ?? "")));

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/customer-holds">Customer holds</Link>
            <Link href="/internal/sage-ready">Ready for Sage queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipper return proof review</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Review physical return/collection proof submitted by shippers. This does not approve credit notes, refund values, DVA/card lines, VAT, or Sage posting.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {params.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{params.success}</p> : null}
          {params.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-900">{params.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Review queue unavailable: {error.message}. Apply the latest Supabase migration before testing.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-sky-700">Pending review</p><p className="mt-1 text-2xl font-semibold">{pendingRows.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-emerald-700">Accepted in view</p><p className="mt-1 text-2xl font-semibold">{acceptedRows.length}</p></div>
          <div className="rounded-3xl border border-orange-200 bg-orange-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-orange-700">Hold/rejected</p><p className="mt-1 text-2xl font-semibold">{queryRows.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Showing closed?</p><p className="mt-1 text-2xl font-semibold">{includeClosed ? "Yes" : "No"}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Review worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Accept only when the proof supports the physical return/collection action. Hold/reject sends it back to shipper task queue.</p>
            </div>
            <Link href={includeClosed ? "/internal/shipper-return-tasks" : "/internal/shipper-return-tasks?include_closed=true"} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">
              {includeClosed ? "Hide closed" : "Show closed"}
            </Link>
          </div>

          {rows.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No shipper return proof submissions match this view.</p> : null}

          <div className="mt-5 grid gap-4">
            {rows.map((row) => {
              const lines = Array.isArray(row.affected_lines) ? row.affected_lines : [];
              return (
                <article key={row.confirmation_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="text-lg font-semibold">{row.order_ref ?? row.order_id}</h3>
                        <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.review_status)}`}>{friendly(row.review_status)}</span>
                      </div>
                      <p className="mt-1 text-sm text-slate-600">{row.shipper_name ?? "Shipper"} · {row.importer_name ?? "Importer"} · {row.retailer_name ?? "Retailer"}</p>
                    </div>
                    <div className="grid gap-2 text-sm sm:grid-cols-3 lg:min-w-[620px]">
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Outcome</p><p className="mt-1 font-semibold">{friendly(row.outcome)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Courier/ref</p><p className="mt-1 font-semibold">{row.courier_name ?? "—"} · {row.tracking_ref ?? "—"}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Submitted</p><p className="mt-1 font-semibold">{row.submitted_at ?? "—"}</p></div>
                    </div>
                  </div>

                  {lines.length > 0 ? (
                    <div className="mt-4 rounded-2xl border border-slate-200 bg-white p-3">
                      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Affected item(s)</p>
                      <div className="mt-2 grid gap-2">
                        {lines.map((line, index) => (
                          <div key={`${line.supplier_invoice_line_id ?? index}`} className="rounded-xl bg-slate-50 p-3 text-sm">
                            <p className="font-semibold">{line.description ?? "Item line"}</p>
                            <p className="mt-1 text-slate-600">Qty {line.qty ?? "—"} · {money(line.amount_gbp)} · {friendly(line.intended_remedy)}</p>
                          </div>
                        ))}
                      </div>
                    </div>
                  ) : null}

                  <details className="mt-4 rounded-2xl border border-slate-200 bg-white p-3 text-sm">
                    <summary className="cursor-pointer font-semibold text-slate-900">View operator instructions and shipper proof</summary>
                    <div className="mt-3 grid gap-2 md:grid-cols-2">
                      {row.operator_return_instructions_file_url ? <a href={row.operator_return_instructions_file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open retailer instructions</a> : null}
                      {row.return_label_file_url ? <a href={row.return_label_file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open return label</a> : null}
                      {row.operator_tracking_evidence_url ? <a href={row.operator_tracking_evidence_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open operator evidence URL</a> : null}
                      {row.proof_url ? <a href={row.proof_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open shipper proof</a> : null}
                    </div>
                    {row.operator_note ? <p className="mt-3 rounded-xl bg-slate-50 p-3 text-slate-700"><span className="font-semibold">Operator note:</span> {row.operator_note}</p> : null}
                    {row.shipper_note ? <p className="mt-3 rounded-xl bg-slate-50 p-3 text-slate-700"><span className="font-semibold">Shipper note:</span> {row.shipper_note}</p> : null}
                    {row.review_notes ? <p className="mt-3 rounded-xl bg-slate-50 p-3 text-slate-700"><span className="font-semibold">Review note:</span> {row.review_notes}</p> : null}
                  </details>

                  {row.review_status === "pending_review" ? (
                    <form action={reviewShipperReturnTaskConfirmationAction} className="mt-4 grid gap-3 rounded-2xl border border-slate-200 bg-white p-3 md:grid-cols-[180px_1fr_auto]">
                      <input type="hidden" name="confirmation_id" value={row.confirmation_id} />
                      <label className="text-sm font-semibold">Decision
                        <select name="decision" required className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal">
                          <option value="">Choose</option>
                          <option value="accepted">Accept</option>
                          <option value="hold">Hold/query</option>
                          <option value="rejected">Reject</option>
                        </select>
                      </label>
                      <label className="text-sm font-semibold">Review notes
                        <input name="review_notes" className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="Required context for hold/reject; optional for accept" />
                      </label>
                      <div className="flex items-end"><button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Save review</button></div>
                    </form>
                  ) : null}
                </article>
              );
            })}
          </div>
        </section>
      </div>
    </main>
  );
}
