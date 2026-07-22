import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import { correctStatementLineInterpretationAction } from "./actions";

type SearchParams = {
  line_id?: string;
  success?: string;
  error?: string;
};

type Row = Record<string, unknown>;

const CLASSIFICATIONS = [
  ["unclassified", "Unclassified"],
  ["customer_order_funding", "Customer order funding"],
  ["supplier_payment", "Supplier payment"],
  ["retailer_refund", "Retailer refund"],
  ["final_balance_payment", "Final balance payment"],
  ["bank_fee", "Bank fee"],
  ["fx_card_difference", "FX / card difference"],
  ["completion_loyalty_source_transfer", "Completion loyalty source transfer"],
  ["completion_loyalty_destination_transfer", "Completion loyalty destination transfer"],
  ["main_bank_shipper_ap", "Main-bank shipper AP"],
  ["exception_control", "Exception control"],
] as const;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
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

function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(value));
}

function friendly(value: unknown) {
  const raw = text(value);
  if (!raw) return "—";
  return cleanUiText(raw.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase()));
}

function badgeClass(status: string) {
  if (status === "controlled") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (status === "integrity_review") return "bg-rose-100 text-rose-800 ring-rose-200";
  return "bg-amber-100 text-amber-800 ring-amber-200";
}

export default async function StatementInterpretationPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const params = searchParams ? await searchParams : {};
  const selectedLineId = text(params.line_id).trim();
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: worklistData, error: worklistError } = await (supabase as any).rpc(
    "internal_statement_line_control_worklist_v1",
    {
      p_importer_id: null,
      p_limit: 200,
      p_offset: 0,
    },
  );

  const rows = ((worklistData ?? []) as Row[]).filter((row) => {
    if (!selectedLineId) return true;
    return text(row.dva_statement_line_id) === selectedLineId;
  });

  const selectedRow = selectedLineId
    ? rows.find((row) => text(row.dva_statement_line_id) === selectedLineId) ?? null
    : null;

  let history: Row[] = [];
  let historyError: string | null = null;

  if (selectedLineId) {
    const result = await supabase
      .from("statement_line_interpretation_corrections")
      .select(
        "id, dva_statement_line_id, raw_direction_snapshot, effective_direction, economic_classification, corrected_display_description, correction_reason, active, created_by_staff_id, created_at, superseded_at",
      )
      .eq("dva_statement_line_id", selectedLineId)
      .order("created_at", { ascending: false });

    history = (result.data ?? []) as Row[];
    historyError = result.error?.message ?? null;
  }

  return (
    <main className="mx-auto max-w-7xl px-6 py-10">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-slate-600 hover:text-slate-950">
            ← Treasury control hub
          </Link>
          <h1 className="mt-3 text-3xl font-bold tracking-tight text-slate-950">Statement interpretation control</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Preserve the original bank/OCR evidence while recording an audited effective direction, economic classification and display description.
          </p>
          <p className="mt-2 text-xs text-slate-500">
            Signed in as {text(staff.full_name) || "staff"} · {text(staff.role_type)}
          </p>
        </div>
        <Link
          href="/internal/dva-reconciliation/statement-interpretation"
          className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50"
        >
          Clear selection
        </Link>
      </div>

      {params.success ? (
        <div className="mt-6 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">
          {params.success}
        </div>
      ) : null}
      {params.error ? (
        <div className="mt-6 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
          {params.error}
        </div>
      ) : null}
      {worklistError ? (
        <div className="mt-6 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
          Statement control worklist unavailable: {worklistError.message}
        </div>
      ) : null}

      <form method="get" className="mt-6 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
        <label className="block text-sm font-semibold text-slate-700">
          Statement-line ID
          <div className="mt-2 flex flex-col gap-3 sm:flex-row">
            <input
              name="line_id"
              defaultValue={selectedLineId}
              placeholder="Paste statement-line UUID"
              className="min-w-0 flex-1 rounded-xl border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-950 focus:outline-none focus:ring-1 focus:ring-slate-950"
            />
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">
              Load statement line
            </button>
          </div>
        </label>
      </form>

      {selectedLineId && !selectedRow && !worklistError ? (
        <div className="mt-6 rounded-2xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-950">
          No accessible worklist row was found for that statement-line ID.
        </div>
      ) : null}

      {selectedRow ? (
        <div className="mt-8 grid gap-6 xl:grid-cols-[1.15fr_0.85fr]">
          <section className="space-y-5">
            <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Immutable bank evidence</p>
                  <h2 className="mt-2 text-xl font-bold text-slate-950">
                    {text(selectedRow.statement_date) || "No date"} · {money(selectedRow.statement_gbp_amount)}
                  </h2>
                </div>
                <span className={`rounded-full px-3 py-1 text-xs font-semibold ring-1 ${badgeClass(text(selectedRow.control_status))}`}>
                  {friendly(selectedRow.control_status)}
                </span>
              </div>

              <dl className="mt-5 grid gap-4 sm:grid-cols-2">
                <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                  <dt className="text-xs font-bold uppercase tracking-wide text-slate-500">Raw direction</dt>
                  <dd className="mt-2 text-lg font-bold text-slate-950">{text(selectedRow.raw_direction).toUpperCase()}</dd>
                </div>
                <div className="rounded-2xl bg-sky-50 p-4 ring-1 ring-sky-200">
                  <dt className="text-xs font-bold uppercase tracking-wide text-sky-700">Effective direction</dt>
                  <dd className="mt-2 text-lg font-bold text-sky-950">{text(selectedRow.effective_direction).toUpperCase()}</dd>
                </div>
                <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200 sm:col-span-2">
                  <dt className="text-xs font-bold uppercase tracking-wide text-slate-500">Raw description</dt>
                  <dd className="mt-2 break-words text-sm leading-6 text-slate-900 [overflow-wrap:anywhere]">
                    {text(selectedRow.raw_description) || "—"}
                  </dd>
                </div>
                <div className="rounded-2xl bg-sky-50 p-4 ring-1 ring-sky-200 sm:col-span-2">
                  <dt className="text-xs font-bold uppercase tracking-wide text-sky-700">Effective display description</dt>
                  <dd className="mt-2 break-words text-sm leading-6 text-sky-950 [overflow-wrap:anywhere]">
                    {text(selectedRow.effective_display_description) || "—"}
                  </dd>
                </div>
              </dl>

              <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                <div className="rounded-2xl border border-slate-200 p-3">
                  <p className="text-xs font-semibold text-slate-500">Classification</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{friendly(selectedRow.effective_economic_classification)}</p>
                </div>
                <div className="rounded-2xl border border-slate-200 p-3">
                  <p className="text-xs font-semibold text-slate-500">Consumed</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{money(selectedRow.active_consumed_gbp)}</p>
                </div>
                <div className="rounded-2xl border border-slate-200 p-3">
                  <p className="text-xs font-semibold text-slate-500">Reserved</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{money(selectedRow.active_reserved_gbp)}</p>
                </div>
                <div className="rounded-2xl border border-slate-200 p-3">
                  <p className="text-xs font-semibold text-slate-500">Remaining</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{money(selectedRow.remaining_unconsumed_gbp)}</p>
                </div>
              </div>

              {text(selectedRow.blocker) ? (
                <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
                  <p className="text-xs font-bold uppercase tracking-wide text-rose-700">Current blocker</p>
                  <p className="mt-1 font-semibold">{friendly(selectedRow.blocker)}</p>
                  <p className="mt-2 text-xs">Next action: {friendly(selectedRow.next_action)}</p>
                </div>
              ) : null}
            </article>

            <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <h2 className="text-lg font-bold text-slate-950">Correction history</h2>
              <p className="mt-1 text-xs text-slate-500">Every replacement remains visible; only one correction can be active.</p>

              {historyError ? (
                <div className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-900">{historyError}</div>
              ) : history.length === 0 ? (
                <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
                  No interpretation corrections have been recorded for this statement line.
                </div>
              ) : (
                <div className="mt-4 space-y-3">
                  {history.map((item) => (
                    <div key={text(item.id)} className="rounded-2xl border border-slate-200 p-4">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <p className="text-sm font-bold text-slate-950">
                          {text(item.effective_direction).toUpperCase()} · {friendly(item.economic_classification)}
                        </p>
                        <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${item.active ? "bg-emerald-100 text-emerald-800" : "bg-slate-100 text-slate-700"}`}>
                          {item.active ? "Active" : "Superseded"}
                        </span>
                      </div>
                      <p className="mt-2 text-xs leading-5 text-slate-600">{text(item.correction_reason)}</p>
                      {text(item.corrected_display_description) ? (
                        <p className="mt-2 text-xs text-slate-500">Display: {text(item.corrected_display_description)}</p>
                      ) : null}
                      <p className="mt-2 text-[11px] text-slate-400">Recorded {text(item.created_at) || "—"}</p>
                    </div>
                  ))}
                </div>
              )}
            </article>
          </section>

          <aside>
            <form action={correctStatementLineInterpretationAction} className="sticky top-6 rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm">
              <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-sky-700">Audited interpretation</p>
              <h2 className="mt-2 text-xl font-bold text-sky-950">Record effective meaning</h2>
              <p className="mt-2 text-xs leading-5 text-sky-900">
                Amount, currency, bank source, raw direction and raw description cannot be changed here.
              </p>

              <div className="mt-5 space-y-4">
                <label className="block text-sm font-semibold text-slate-700">
                  Effective direction
                  <select
                    name="effective_direction"
                    required
                    defaultValue={text(selectedRow.effective_direction) || text(selectedRow.raw_direction)}
                    className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-sky-900 focus:outline-none focus:ring-1 focus:ring-sky-900"
                  >
                    <option value="in">IN</option>
                    <option value="out">OUT</option>
                  </select>
                </label>

                <label className="block text-sm font-semibold text-slate-700">
                  Economic classification
                  <select
                    name="economic_classification"
                    required
                    defaultValue={text(selectedRow.effective_economic_classification) || "unclassified"}
                    className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-sky-900 focus:outline-none focus:ring-1 focus:ring-sky-900"
                  >
                    {CLASSIFICATIONS.map(([value, label]) => (
                      <option key={value} value={value}>{label}</option>
                    ))}
                  </select>
                </label>

                <label className="block text-sm font-semibold text-slate-700">
                  Effective display description
                  <textarea
                    name="corrected_display_description"
                    rows={3}
                    defaultValue={text(selectedRow.effective_display_description)}
                    className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-sky-900 focus:outline-none focus:ring-1 focus:ring-sky-900"
                  />
                </label>

                <label className="block text-sm font-semibold text-slate-700">
                  Correction reason
                  <textarea
                    name="correction_reason"
                    rows={4}
                    minLength={8}
                    required
                    placeholder="Explain why the bank/OCR interpretation is incorrect and what evidence supports the correction."
                    className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-sky-900 focus:outline-none focus:ring-1 focus:ring-sky-900"
                  />
                </label>
              </div>

              <button className="mt-5 w-full rounded-xl bg-sky-950 px-4 py-3 text-sm font-bold text-white hover:bg-sky-900">
                Save audited interpretation
              </button>
            </form>
          </aside>
        </div>
      ) : null}

      {!selectedLineId && !worklistError ? (
        <section className="mt-8">
          <div className="mb-4 flex items-end justify-between gap-4">
            <div>
              <h2 className="text-xl font-bold text-slate-950">Recent statement-control rows</h2>
              <p className="mt-1 text-sm text-slate-500">Select a row to inspect or correct its effective interpretation.</p>
            </div>
            <p className="text-xs text-slate-500">Showing {rows.length} rows</p>
          </div>

          <div className="space-y-3">
            {rows.map((row) => {
              const id = text(row.dva_statement_line_id);
              return (
                <Link
                  key={id}
                  href={`/internal/dva-reconciliation/statement-interpretation?line_id=${encodeURIComponent(id)}`}
                  className="block rounded-2xl border border-slate-200 bg-white p-4 shadow-sm transition hover:border-sky-300 hover:bg-sky-50"
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${badgeClass(text(row.control_status))}`}>
                          {friendly(row.control_status)}
                        </span>
                        <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700">
                          {text(row.effective_direction).toUpperCase()}
                        </span>
                        <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-semibold text-sky-800">
                          {friendly(row.effective_economic_classification)}
                        </span>
                      </div>
                      <p className="mt-3 text-sm font-bold text-slate-950">
                        {text(row.statement_date) || "No date"} · {money(row.statement_gbp_amount)}
                      </p>
                      <p className="mt-1 max-w-4xl truncate text-xs text-slate-500">{text(row.effective_display_description) || "No description"}</p>
                    </div>
                    <div className="text-right">
                      <p className="text-xs font-semibold text-slate-500">Remaining</p>
                      <p className="mt-1 text-sm font-bold text-slate-950">{money(row.remaining_unconsumed_gbp)}</p>
                    </div>
                  </div>
                </Link>
              );
            })}
          </div>
        </section>
      ) : null}
    </main>
  );
}
