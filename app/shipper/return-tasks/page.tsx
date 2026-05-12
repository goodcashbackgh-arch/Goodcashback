import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { submitReturnTaskConfirmationAction } from "../actions";

type AffectedLine = {
  supplier_invoice_line_id?: string | null;
  description?: string | null;
  qty?: number | string | null;
  amount_gbp?: number | string | null;
  intended_remedy?: string | null;
  line_status?: string | null;
};

type ReturnTask = {
  return_tracking_submission_id: string;
  dispute_id: string;
  order_id: string;
  order_ref: string | null;
  importer_name: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  retailer_return_instructions_file_url: string | null;
  return_label_file_url: string | null;
  operator_return_proof_file_url: string | null;
  operator_note: string | null;
  is_final_return_yn: boolean | null;
  operator_review_status: string | null;
  submitted_at: string | null;
  affected_lines: AffectedLine[] | null;
  latest_confirmation_id: string | null;
  latest_shipper_outcome: string | null;
  latest_shipper_proof_url: string | null;
  latest_shipper_note: string | null;
  latest_shipper_submitted_at: string | null;
  latest_shipper_review_status: string | null;
  latest_shipper_review_notes: string | null;
  task_status: string | null;
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
  if (status === "ready_to_action") return "bg-amber-100 text-amber-900";
  if (status === "submitted_for_review") return "bg-sky-100 text-sky-900";
  if (status === "accepted") return "bg-emerald-100 text-emerald-900";
  if (status === "held_query") return "bg-orange-100 text-orange-900";
  return "bg-slate-100 text-slate-700";
}

function matchesStatus(task: ReturnTask, status: string) {
  if (status === "all") return true;
  return task.task_status === status;
}

function filterLabel(status: string) {
  if (status === "ready_to_action") return "Ready to action";
  if (status === "submitted_for_review") return "Submitted / awaiting review";
  if (status === "accepted") return "Accepted";
  if (status === "held_query") return "Held / query";
  return "All";
}

export default async function ShipperReturnTasksPage({
  searchParams,
}: {
  searchParams?: Promise<{ status?: string; success?: string; error?: string }>;
}) {
  const params = searchParams ? await searchParams : {};
  const selectedStatus = params.status ?? "ready_to_action";
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, role_at_shipper, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("shipper_return_tasks_v1");
  const allTasks = (data ?? []) as ReturnTask[];
  const tasks = allTasks.filter((task) => matchesStatus(task, selectedStatus));
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  const counts = {
    ready: allTasks.filter((task) => task.task_status === "ready_to_action").length,
    review: allTasks.filter((task) => task.task_status === "submitted_for_review").length,
    accepted: allTasks.filter((task) => task.task_status === "accepted").length,
    query: allTasks.filter((task) => task.task_status === "held_query").length,
  };

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Package receipt dashboard</Link>
            <Link href="/shipper/customer-holds">Customer holds</Link>
            <Link href="/shipper/package-receipts">Package receipt actions</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Return tasks</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            Return tasks are created from operator return/collection instructions on approved refund exceptions. Confirm only the physical action: collected, handed to courier, returned, unable to return, or query.
          </p>
          <p className="mt-3 text-sm text-slate-600">Welcome: <span className="font-semibold text-slate-900">{shipperUser.full_name}</span> · {shipper?.name ?? "Shipper"}</p>
          {params.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{params.success}</p> : null}
          {params.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-900">{params.error}</p> : null}
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Return task queue unavailable: {error.message}. Apply the latest Supabase migration before testing.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-amber-700">Ready to action</p><p className="mt-1 text-2xl font-semibold">{counts.ready}</p></div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-sky-700">Awaiting review</p><p className="mt-1 text-2xl font-semibold">{counts.review}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-emerald-700">Accepted</p><p className="mt-1 text-2xl font-semibold">{counts.accepted}</p></div>
          <div className="rounded-3xl border border-orange-200 bg-orange-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-orange-700">Held / query</p><p className="mt-1 text-2xl font-semibold">{counts.query}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Task worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Operator instructions stay visible here. Your confirmation is reviewed by supervisor before the physical return loop is treated as closed.</p>
            </div>
            <form action="/shipper/return-tasks" className="grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:grid-cols-[1fr_auto]">
              <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Status
                <select name="status" defaultValue={selectedStatus} className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950">
                  <option value="ready_to_action">Ready to action</option>
                  <option value="submitted_for_review">Submitted / awaiting review</option>
                  <option value="accepted">Accepted</option>
                  <option value="held_query">Held / query</option>
                  <option value="all">All</option>
                </select>
              </label>
              <div className="flex items-end gap-2"><button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply</button><Link href="/shipper/return-tasks" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100">Reset</Link></div>
            </form>
          </div>
          <p className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">Showing {tasks.length} task(s) · {filterLabel(selectedStatus)}</p>

          {tasks.length === 0 ? <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No return tasks match this view.</p> : null}

          <div className="mt-5 grid gap-4">
            {tasks.map((task) => {
              const lines = Array.isArray(task.affected_lines) ? task.affected_lines : [];
              const canSubmit = task.task_status === "ready_to_action" || task.task_status === "held_query";
              return (
                <article key={task.return_tracking_submission_id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <h3 className="text-lg font-semibold">{task.order_ref ?? task.order_id}</h3>
                        <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(task.task_status)}`}>{friendly(task.task_status)}</span>
                      </div>
                      <p className="mt-1 text-sm text-slate-600">{task.importer_name ?? "Importer"} · {task.retailer_name ?? "Retailer"}</p>
                    </div>
                    <div className="grid gap-2 text-sm sm:grid-cols-3 lg:min-w-[620px]">
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Courier</p><p className="mt-1 font-semibold">{task.courier_name ?? "—"}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Collection/tracking ref</p><p className="mt-1 font-semibold">{task.tracking_ref ?? "—"}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Date</p><p className="mt-1 font-semibold">{task.tracking_date ?? "—"}</p></div>
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
                    <summary className="cursor-pointer font-semibold text-slate-900">View operator return/collection instructions</summary>
                    <div className="mt-3 grid gap-2 md:grid-cols-2">
                      {task.retailer_return_instructions_file_url ? <a href={task.retailer_return_instructions_file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open retailer instructions</a> : null}
                      {task.return_label_file_url ? <a href={task.return_label_file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open return label</a> : null}
                      {task.tracking_evidence_url ? <a href={task.tracking_evidence_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open tracking/evidence URL</a> : null}
                      {task.operator_return_proof_file_url ? <a href={task.operator_return_proof_file_url} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 font-semibold text-sky-700 hover:underline">Open operator return proof</a> : null}
                    </div>
                    {task.operator_note ? <p className="mt-3 rounded-xl bg-slate-50 p-3 text-slate-700"><span className="font-semibold">Operator note:</span> {task.operator_note}</p> : null}
                  </details>

                  {task.latest_confirmation_id ? (
                    <div className="mt-4 rounded-2xl border border-slate-200 bg-white p-3 text-sm">
                      <p className="font-semibold">Latest shipper confirmation</p>
                      <p className="mt-1 text-slate-700">Outcome: {friendly(task.latest_shipper_outcome)} · Review: {friendly(task.latest_shipper_review_status)}</p>
                      {task.latest_shipper_proof_url ? <a href={task.latest_shipper_proof_url} target="_blank" rel="noreferrer" className="mt-2 inline-flex font-semibold text-sky-700 underline">Open shipper proof</a> : null}
                      {task.latest_shipper_note ? <p className="mt-2 text-slate-700">{task.latest_shipper_note}</p> : null}
                      {task.latest_shipper_review_notes ? <p className="mt-2 rounded-xl bg-slate-50 p-3 text-slate-700"><span className="font-semibold">Supervisor note:</span> {task.latest_shipper_review_notes}</p> : null}
                    </div>
                  ) : null}

                  {canSubmit ? (
                    <form action={submitReturnTaskConfirmationAction} className="mt-4 grid gap-3 rounded-2xl border border-slate-200 bg-white p-3 md:grid-cols-2">
                      <input type="hidden" name="return_tracking_submission_id" value={task.return_tracking_submission_id} />
                      <label className="text-sm font-semibold">Outcome
                        <select name="outcome" required className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal">
                          <option value="">Choose outcome</option>
                          <option value="collected">Collected</option>
                          <option value="handed_to_courier">Handed to courier</option>
                          <option value="returned_to_retailer">Returned to retailer</option>
                          <option value="unable_to_return">Unable to return</option>
                          <option value="query">Query / need help</option>
                        </select>
                      </label>
                      <label className="text-sm font-semibold">Proof URL, optional
                        <input name="proof_url" className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="Paste proof URL if already uploaded" />
                      </label>
                      <label className="text-sm font-semibold md:col-span-2">Upload proof/image, optional
                        <input name="proof_file" type="file" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal" />
                      </label>
                      <label className="text-sm font-semibold md:col-span-2">Note
                        <textarea name="note" rows={3} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal" placeholder="Add handover, collection, courier, or problem details." />
                      </label>
                      <div className="md:col-span-2"><button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Submit for supervisor review</button></div>
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
