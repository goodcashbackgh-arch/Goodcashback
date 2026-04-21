import { revalidatePath } from "next/cache";
// Adjust this import if your Supabase server helper lives elsewhere.
import { createClient } from "@/lib/supabase/server";

type SearchParams = {
  ok?: string;
  error?: string;
};

function money(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(n);
}

function shortId(value: string | null | undefined) {
  if (!value) return "—";
  return `${value.slice(0, 8)}…`;
}

async function generateSuggestionsAction(formData: FormData) {
  "use server";

  const supabase = await createClient();
  const dvaStatementLineId = String(formData.get("dva_statement_line_id") || "");

  if (!dvaStatementLineId) {
    throw new Error("Missing DVA statement line ID.");
  }

  const { error } = await supabase.rpc("generate_order_match_suggestions", {
    p_dva_statement_line_id: dvaStatementLineId,
  });

  if (error) throw error;

  revalidatePath("/staff/day2");
}

async function acceptSuggestionAndReconcileAction(formData: FormData) {
  "use server";

  const supabase = await createClient();

  const dvaStatementLineId = String(formData.get("dva_statement_line_id") || "");
  const suggestedOrderId = String(formData.get("suggested_order_id") || "");
  const staffId = String(formData.get("staff_id") || "");
  const notes = String(formData.get("notes") || "");

  if (!dvaStatementLineId || !suggestedOrderId || !staffId) {
    throw new Error("DVA line, suggested order, and staff ID are required.");
  }

  const { error } = await supabase.rpc(
    "accept_order_match_suggestion_and_reconcile",
    {
      p_dva_statement_line_id: dvaStatementLineId,
      p_suggested_order_id: suggestedOrderId,
      p_staff_id: staffId,
      p_notes: notes || null,
    }
  );

  if (error) throw error;

  revalidatePath("/staff/day2");
}

async function manualReconcileAction(formData: FormData) {
  "use server";

  const supabase = await createClient();

  const dvaStatementLineId = String(formData.get("dva_statement_line_id") || "");
  const orderId = String(formData.get("order_id") || "");
  const staffId = String(formData.get("staff_id") || "");
  const notes = String(formData.get("notes") || "");

  if (!dvaStatementLineId || !orderId || !staffId) {
    throw new Error("DVA line, order ID, and staff ID are required.");
  }

  const { error } = await supabase.rpc("confirm_reconciliation_to_order", {
    p_dva_statement_line_id: dvaStatementLineId,
    p_order_id: orderId,
    p_reconciled_by_staff_id: staffId,
    p_notes: notes || null,
  });

  if (error) throw error;

  revalidatePath("/staff/day2");
}

async function applyCreditAction(formData: FormData) {
  "use server";

  const supabase = await createClient();

  const orderId = String(formData.get("order_id") || "");
  const amount = Number(formData.get("amount_gbp") || 0);
  const staffIdRaw = String(formData.get("staff_id") || "");
  const notes = String(formData.get("notes") || "");

  if (!orderId || !amount || amount <= 0) {
    throw new Error("Order ID and positive GBP amount are required.");
  }

  const { error } = await supabase.rpc("apply_importer_credit_to_order", {
    p_order_id: orderId,
    p_amount_gbp: amount,
    p_created_by_staff_id: staffIdRaw || null,
    p_notes: notes || null,
  });

  if (error) throw error;

  revalidatePath("/staff/day2");
}

export default async function Day2Page({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const params = (await searchParams) ?? {};
  const supabase = await createClient();

  const [{ data: orders, error: ordersError }, { data: dvaLines, error: dvaError }] =
    await Promise.all([
      supabase
        .from("day2_order_worklist_vw")
        .select("*")
        .order("created_at", { ascending: false }),
      supabase
        .from("day2_dva_review_worklist_vw")
        .select("*")
        .order("created_at", { ascending: false }),
    ]);

  if (ordersError) throw ordersError;
  if (dvaError) throw dvaError;

  return (
    <main className="mx-auto max-w-7xl p-6 space-y-8">
      <header className="space-y-2">
        <h1 className="text-2xl font-semibold">Day 2 Funding Control</h1>
        <p className="text-sm text-slate-600">
          Thin staff UI only. Verified backend objects only.
        </p>
        <div className="rounded-xl border bg-slate-50 p-3 text-sm text-slate-700">
          For now, staff ID is entered manually in the action forms until staff auth mapping is wired.
        </div>
        {params.ok ? (
          <div className="rounded-xl border border-green-200 bg-green-50 p-3 text-sm text-green-800">
            {params.ok}
          </div>
        ) : null}
        {params.error ? (
          <div className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {params.error}
          </div>
        ) : null}
      </header>

      <section className="space-y-3">
        <div>
          <h2 className="text-xl font-semibold">Order worklist</h2>
          <p className="text-sm text-slate-600">
            Staff view of funding threshold, current funding, and remaining gap.
          </p>
        </div>

        <div className="overflow-x-auto rounded-2xl border">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left">
              <tr>
                <th className="p-3">Order</th>
                <th className="p-3">Importer</th>
                <th className="p-3">Auth ref</th>
                <th className="p-3">Threshold</th>
                <th className="p-3">DVA</th>
                <th className="p-3">Credit</th>
                <th className="p-3">Funded</th>
                <th className="p-3">Gap</th>
                <th className="p-3">Status</th>
                <th className="p-3">Action</th>
              </tr>
            </thead>
            <tbody>
              {(orders ?? []).map((row: any) => {
                const isFunded = Boolean(row.already_funded_yn);
                return (
                  <tr key={row.order_id} className="border-t align-top">
                    <td className="p-3">
                      <div className="font-medium">{row.order_ref}</div>
                      <div className="text-xs text-slate-500">{shortId(row.order_id)}</div>
                    </td>
                    <td className="p-3">
                      <div>{row.importer_name}</div>
                      <div className="text-xs text-slate-500">
                        {row.importer_country_name} · {row.importer_currency_code}
                      </div>
                    </td>
                    <td className="p-3">{row.payment_auth_id ?? "—"}</td>
                    <td className="p-3">{money(row.purchase_funding_threshold_gbp)}</td>
                    <td className="p-3">{money(row.confirmed_dva_funding_gbp)}</td>
                    <td className="p-3">{money(row.applied_credit_gbp)}</td>
                    <td className="p-3">{money(row.funded_total_gbp)}</td>
                    <td className="p-3">{money(row.gap_remaining_gbp)}</td>
                    <td className="p-3">
                      <div>{row.status}</div>
                      <div className="text-xs text-slate-500">
                        {isFunded ? "Funded" : "Open"}
                      </div>
                    </td>
                    <td className="p-3">
                      {isFunded ? (
                        <span className="text-xs text-slate-500">No action</span>
                      ) : (
                        <form action={applyCreditAction} className="space-y-2 min-w-[240px]">
                          <input type="hidden" name="order_id" value={row.order_id} />
                          <input
                            name="amount_gbp"
                            type="number"
                            step="0.01"
                            min="0.01"
                            placeholder="Credit GBP"
                            className="w-full rounded-lg border px-3 py-2"
                            required
                          />
                          <input
                            name="staff_id"
                            type="text"
                            placeholder="Staff ID (optional here)"
                            className="w-full rounded-lg border px-3 py-2"
                          />
                          <input
                            name="notes"
                            type="text"
                            placeholder="Notes"
                            className="w-full rounded-lg border px-3 py-2"
                          />
                          <button
                            type="submit"
                            className="rounded-lg bg-slate-900 px-3 py-2 text-white"
                          >
                            Apply credit
                          </button>
                        </form>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <section className="space-y-3">
        <div>
          <h2 className="text-xl font-semibold">DVA review worklist</h2>
          <p className="text-sm text-slate-600">
            Staff review of incoming statement lines, top suggestion, and reconciliation state.
          </p>
        </div>

        <div className="space-y-4">
          {(dvaLines ?? []).map((row: any) => {
            const unmatched = row.match_status === "unmatched";
            const hasSuggestion = Boolean(row.suggested_order_id);
            const alreadyReconciled = Boolean(row.reconciliation_id);

            return (
              <div key={row.dva_statement_line_id} className="rounded-2xl border p-4 space-y-3">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="space-y-1">
                    <div className="font-medium">
                      {row.importer_name} · {row.source_bank.toUpperCase()}
                    </div>
                    <div className="text-sm text-slate-600">
                      Line {row.line_order} · {row.statement_date} · {row.reference_raw}
                    </div>
                    <div className="text-xs text-slate-500">
                      DVA line: {shortId(row.dva_statement_line_id)} · Auth:{" "}
                      {row.auth_id_ref ?? "—"}
                    </div>
                  </div>
                  <div className="text-right text-sm">
                    <div>Local: {row.amount_local_ccy} {row.local_ccy}</div>
                    <div>GBP: {money(row.amount_gbp_equivalent)}</div>
                    <div className="text-xs text-slate-500">
                      FX {row.fx_rate_applied} · markup {row.card_markup_pct_applied}%
                    </div>
                  </div>
                </div>

                <div className="grid gap-3 md:grid-cols-3">
                  <div className="rounded-xl bg-slate-50 p-3 text-sm">
                    <div className="font-medium">Current state</div>
                    <div>Match status: {row.match_status}</div>
                    <div>
                      Reconciliation: {alreadyReconciled ? row.reconciliation_type : "—"}
                    </div>
                    <div>
                      Reconciled order: {row.reconciled_order_id ? shortId(row.reconciled_order_id) : "—"}
                    </div>
                  </div>

                  <div className="rounded-xl bg-slate-50 p-3 text-sm">
                    <div className="font-medium">Top suggestion</div>
                    <div>Order: {row.suggested_order_ref ?? "—"}</div>
                    <div>Confidence: {row.suggested_confidence ?? "—"}</div>
                    <div>Variance GBP: {row.suggested_variance_gbp ?? "—"}</div>
                    <div>Variance days: {row.suggested_variance_days ?? "—"}</div>
                  </div>

                  <div className="rounded-xl bg-slate-50 p-3 text-sm">
                    <div className="font-medium">Staff trace</div>
                    <div>Accepted by: {row.accepted_by_staff_id ?? "—"}</div>
                    <div>Accepted at: {row.accepted_at ?? "—"}</div>
                    <div>Reconciled by: {row.reconciled_by_staff_id ?? "—"}</div>
                  </div>
                </div>

                <div className="flex flex-wrap gap-3">
                  {unmatched ? (
                    <form action={generateSuggestionsAction}>
                      <input
                        type="hidden"
                        name="dva_statement_line_id"
                        value={row.dva_statement_line_id}
                      />
                      <button
                        type="submit"
                        className="rounded-lg border px-3 py-2 text-sm"
                      >
                        Generate suggestions
                      </button>
                    </form>
                  ) : null}

                  {unmatched && hasSuggestion && !alreadyReconciled ? (
                    <form
                      action={acceptSuggestionAndReconcileAction}
                      className="flex flex-wrap gap-2"
                    >
                      <input
                        type="hidden"
                        name="dva_statement_line_id"
                        value={row.dva_statement_line_id}
                      />
                      <input
                        type="hidden"
                        name="suggested_order_id"
                        value={row.suggested_order_id}
                      />
                      <input
                        name="staff_id"
                        type="text"
                        placeholder="Staff ID"
                        className="rounded-lg border px-3 py-2 text-sm"
                        required
                      />
                      <input
                        name="notes"
                        type="text"
                        placeholder="Notes"
                        className="rounded-lg border px-3 py-2 text-sm"
                      />
                      <button
                        type="submit"
                        className="rounded-lg bg-slate-900 px-3 py-2 text-sm text-white"
                      >
                        Accept suggestion + reconcile
                      </button>
                    </form>
                  ) : null}

                  {unmatched && !alreadyReconciled ? (
                    <form action={manualReconcileAction} className="flex flex-wrap gap-2">
                      <input
                        type="hidden"
                        name="dva_statement_line_id"
                        value={row.dva_statement_line_id}
                      />
                      <input
                        name="order_id"
                        type="text"
                        placeholder="Manual order ID"
                        className="rounded-lg border px-3 py-2 text-sm"
                        required
                      />
                      <input
                        name="staff_id"
                        type="text"
                        placeholder="Staff ID"
                        className="rounded-lg border px-3 py-2 text-sm"
                        required
                      />
                      <input
                        name="notes"
                        type="text"
                        placeholder="Notes"
                        className="rounded-lg border px-3 py-2 text-sm"
                      />
                      <button
                        type="submit"
                        className="rounded-lg border px-3 py-2 text-sm"
                      >
                        Manual reconcile
                      </button>
                    </form>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
      </section>
    </main>
  );
}