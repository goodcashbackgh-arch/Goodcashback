import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { answerOrderEvidenceQueryAction, submitSupplierInvoiceAction } from "./actions";

type EvidenceQuery = {
  id: string;
  order_id: string;
  query_type: string | null;
  message: string | null;
  status: string | null;
  created_at: string | null;
  answer_text: string | null;
  answered_at: string | null;
};

function formatValue(value: string | null | undefined) {
  if (!value) return "—";
  return value;
}

export default async function ImporterEvidenceQueriesPage({
  searchParams,
}: {
  searchParams?: Promise<{ query_success?: string; query_error?: string }>;
}) {
  const queryParams = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirect("/auth/check");
  }

  const { data: queries, error: queriesError } = await supabase
    .from("order_evidence_queries")
    .select("id, order_id, query_type, message, status, created_at, answer_text, answered_at")
    .in("status", ["open", "answered"])
    .order("created_at", { ascending: false });

  const orderIds = Array.from(new Set((queries ?? []).map((row) => row.order_id)));
  const { data: orders } = orderIds.length
    ? await supabase.from("orders").select("id, order_ref").in("id", orderIds)
    : { data: [] as { id: string; order_ref: string | null }[] };

  const orderRefById = new Map((orders ?? []).map((order) => [order.id, order.order_ref]));

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-6xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/importer" className="text-sm font-semibold text-sky-600">
            ← Back to importer dashboard
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Evidence queries</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Importer query inbox</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Open and answered evidence queries for your authorised importers.
          </p>
          <p className="mt-2 text-sm text-slate-600">Signed in as: {operator.full_name}</p>

          {queryParams.query_success ? (
            <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
              {queryParams.query_success}
            </p>
          ) : null}
          {queryParams.query_error ? (
            <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">
              {queryParams.query_error}
            </p>
          ) : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Inbox</h2>
          {queriesError ? (
            <p className="mt-4 text-sm text-rose-700">Failed to load evidence queries: {queriesError.message}</p>
          ) : queries && queries.length > 0 ? (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">created_at</th>
                    <th className="px-4 py-3 font-semibold">order</th>
                    <th className="px-4 py-3 font-semibold">query_type</th>
                    <th className="px-4 py-3 font-semibold">message</th>
                    <th className="px-4 py-3 font-semibold">status</th>
                    <th className="px-4 py-3 font-semibold">answer</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {(queries as EvidenceQuery[]).map((query) => {
                    const orderRef = orderRefById.get(query.order_id);

                    return (
                      <tr key={query.id}>
                        <td className="px-4 py-3">{formatValue(query.created_at)}</td>
                        <td className="px-4 py-3">
                          <div className="font-medium">{formatValue(orderRef)}</div>
                          <div className="text-xs text-slate-500">{query.order_id}</div>
                        </td>
                        <td className="px-4 py-3">{formatValue(query.query_type)}</td>
                        <td className="max-w-lg px-4 py-3">{formatValue(query.message)}</td>
                        <td className="px-4 py-3">{formatValue(query.status)}</td>
                        <td className="max-w-md px-4 py-3">
                          {query.status === "open" ? (
                            <div className="space-y-4">
                              {query.query_type === "missing_invoice" ? (
                                <form action={submitSupplierInvoiceAction} className="space-y-2 rounded-xl border border-slate-200 p-3">
                                  <input type="hidden" name="order_id" value={query.order_id} />
                                  <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">
                                    invoice_ref
                                    <input
                                      name="invoice_ref"
                                      required
                                      className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                                      placeholder="Retailer invoice reference"
                                    />
                                  </label>
                                  <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">
                                    invoice_pdf_url
                                    <input
                                      name="invoice_pdf_url"
                                      type="url"
                                      required
                                      className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                                      placeholder="https://..."
                                    />
                                  </label>
                                  <button
                                    type="submit"
                                    className="rounded-xl bg-emerald-600 px-3 py-2 text-sm font-semibold text-white hover:bg-emerald-500"
                                  >
                                    Submit invoice
                                  </button>
                                </form>
                              ) : null}
                              <form action={answerOrderEvidenceQueryAction} className="space-y-2">
                                <input type="hidden" name="query_id" value={query.id} />
                                <textarea
                                  name="answer_text"
                                  required
                                  rows={3}
                                  className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                                  placeholder="Type your answer"
                                />
                                <button
                                  type="submit"
                                  className="rounded-xl bg-sky-600 px-3 py-2 text-sm font-semibold text-white hover:bg-sky-500"
                                >
                                  Submit answer
                                </button>
                              </form>
                            </div>
                          ) : (
                            <div className="space-y-1">
                              <p>{formatValue(query.answer_text)}</p>
                              <p className="text-xs text-slate-500">Answered at: {formatValue(query.answered_at)}</p>
                            </div>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="mt-4 text-sm text-slate-600">No open or answered evidence queries available.</p>
          )}
        </section>
      </div>
    </main>
  );
}
