import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import {
  applyImporterCreditAction,
  reconcileDvaLineToOrderAction,
} from "./actions";

type DataRow = Record<string, unknown>;

type PanelResult = {
  title: string;
  description: string;
  source: string;
  role: string;
  rows: DataRow[];
  error: string | null;
};

const panels = [
  {
    title: "DVA review worklist",
    description:
      "Primary staff worklist for bank/card lines that need review, matching, or allocation.",
    source: "day2_dva_review_worklist_vw",
    role: "Primary UI source",
  },
  {
    title: "Order funding positions",
    description:
      "Orders with their funding position, gaps, funded totals, and closure readiness.",
    source: "order_funding_position_vw",
    role: "Primary UI source",
  },
  {
    title: "Importer credit balances",
    description: "Available importer credit that can be applied to future orders.",
    source: "importer_balance_vw",
    role: "Primary UI source",
  },
  {
    title: "Recent DVA lines",
    description:
      "Raw DVA statement lines. This is diagnostic only; the staff page should normally use the DVA review worklist view.",
    source: "dva_statement_lines",
    role: "Diagnostic only",
  },
  {
    title: "Recent funding events",
    description:
      "Immutable funding events created by reconciliation, credit, or adjustments.",
    source: "order_funding_events",
    role: "Audit trail",
  },
] as const;

const preferredBySource: Record<string, string[]> = {
  day2_dva_review_worklist_vw: [
    "importer_name",
    "company_name",
    "trading_name",
    "order_ref",
    "payment_auth_id",
    "auth_id_ref",
    "reference_raw",
    "match_status",
    "amount_gbp_equivalent",
    "reconciled_gbp_amount",
    "created_at",
    "reconciled_at",
  ],
  order_funding_position_vw: [
    "order_ref",
    "payment_auth_id",
    "status",
    "order_total_gbp_declared",
    "funded_total_gbp",
    "gap_remaining_gbp",
    "available_credit_gbp",
    "threshold_met_yn",
    "already_funded_yn",
    "funded_at",
    "created_at",
  ],
  importer_balance_vw: [
    "importer_id",
    "available_credit_gbp",
    "pending_refund_gbp",
    "active_order_funding_gbp",
    "payout_in_progress_gbp",
    "last_refreshed_at",
  ],
  dva_statement_lines: [
    "statement_date",
    "reference_raw",
    "auth_id_ref",
    "direction",
    "amount_local_ccy",
    "local_ccy",
    "amount_gbp_equivalent",
    "match_status",
    "created_at",
  ],
  order_funding_events: [
    "order_ref",
    "event_type",
    "amount_gbp",
    "resulting_funded_total_gbp",
    "source_table",
    "source_entity_id",
    "notes",
    "created_at",
  ],
};

function formatValue(value: unknown) {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number") return value.toLocaleString("en-GB");
  if (typeof value === "string") {
    if (value.length > 90) return `${value.slice(0, 87)}...`;
    return value;
  }
  return JSON.stringify(value);
}

function asNumber(value: unknown) {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function asString(value: unknown) {
  return typeof value === "string" ? value : "";
}

function asBoolean(value: unknown) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return false;
}

function allColumns(rows: DataRow[]) {
  return Array.from(new Set(rows.flatMap((row) => Object.keys(row))));
}

function visibleColumns(source: string, rows: DataRow[]) {
  const present = new Set(allColumns(rows));
  const preferred = preferredBySource[source] ?? [];
  const selected = preferred.filter((key) => present.has(key));

  if (selected.length > 0) return selected.slice(0, 10);
  return Object.keys(rows[0] ?? {}).slice(0, 10);
}

async function readPanel(
  source: string
): Promise<Omit<PanelResult, "title" | "description" | "role">> {
  const supabase = await createClient();
  const { data, error } = await supabase.from(source).select("*").limit(10);

  return {
    source,
    rows: (data ?? []) as DataRow[],
    error: error?.message ?? null,
  };
}

export default async function InternalFundingPage({
  searchParams,
}: {
  searchParams?: Promise<{
    credit_success?: string;
    credit_error?: string;
    dva_success?: string;
    dva_error?: string;
  }>;
}) {
  const params = searchParams ? await searchParams : {};

  const results = await Promise.all(
    panels.map(async (panel) => ({
      ...panel,
      ...(await readPanel(panel.source)),
    }))
  );

  const fundingPosition = results.find(
    (panel) => panel.source === "order_funding_position_vw"
  );
  const fundingPositionColumns = fundingPosition ? allColumns(fundingPosition.rows) : [];

  const missingUsefulFundingColumns = [
    "order_total_gbp_declared",
    "gap_remaining_gbp",
    "requires_admin_review_yn",
    "funded_at",
  ].filter((column) => !fundingPositionColumns.includes(column));

  const creditBalance = results.find(
    (panel) => panel.source === "importer_balance_vw"
  );

  const creditByImporter = new Map(
    (creditBalance?.rows ?? []).map((row) => [
      asString(row.importer_id),
      asNumber(row.available_credit_gbp),
    ])
  );

  const creditCandidates = (fundingPosition?.rows ?? []).map((row) => {
    const importerId = asString(row.importer_id);
    const orderId = asString(row.order_id);
    const gap = asNumber(row.gap_remaining_gbp);
    const availableCredit = creditByImporter.get(importerId) ?? 0;
    const maxApplyAmount = Math.min(gap, availableCredit);
    const alreadyFunded = asBoolean(row.already_funded_yn) || gap <= 0;

    return {
      importerId,
      orderId,
      orderRef: asString(row.order_ref),
      paymentAuthId: asString(row.payment_auth_id),
      status: asString(row.status),
      gap,
      availableCredit,
      maxApplyAmount,
      alreadyFunded,
      canApply: Boolean(importerId && orderId && maxApplyAmount > 0 && !alreadyFunded),
    };
  });

  const gapByOrder = new Map(
    (fundingPosition?.rows ?? []).map((row) => [
      asString(row.order_id),
      asNumber(row.gap_remaining_gbp),
    ])
  );

  const dvaWorklist = results.find(
    (panel) => panel.source === "day2_dva_review_worklist_vw"
  );

  const dvaReconcileCandidates = (dvaWorklist?.rows ?? [])
    .map((row) => {
      const dvaStatementLineId = asString(row.dva_statement_line_id);
      const orderId = asString(row.suggested_order_id);
      const matchSuggestionId = asString(row.match_suggestion_id);
      const suggestedOrderRef = asString(row.suggested_order_ref);
      const amountGbp = asNumber(row.amount_gbp_equivalent);
      const gap = gapByOrder.get(orderId);
      const alreadyReconciled =
        Boolean(asString(row.reconciliation_id)) || asString(row.match_status) === "reconciled";

      return {
        dvaStatementLineId,
        orderId,
        orderRef: suggestedOrderRef,
        matchSuggestionId,
        amountGbp,
        gap: typeof gap === "number" ? gap : null,
        canReconcile: Boolean(
          dvaStatementLineId &&
            orderId &&
            amountGbp > 0 &&
            typeof gap === "number" &&
            !alreadyReconciled
        ),
        alreadyReconciled,
      };
    })
    .filter((candidate) => candidate.dvaStatementLineId);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">
            ← Back to internal dashboard
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
            Day 2 funding workflow
          </p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">
            Funding queue
          </h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Read-only operational view for DVA/card lines, funding positions,
            importer balances, and immutable funding events. Apply Credit and
            DVA Reconcile are the staff-only write actions currently exposed.
          </p>
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          {results.slice(0, 3).map((panel) => (
            <div
              key={panel.source}
              className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"
            >
              <p className="text-sm text-slate-500">{panel.title}</p>
              <p className="mt-2 text-3xl font-semibold">
                {panel.error ? "—" : panel.rows.length}
              </p>
              <p className="mt-3 text-xs leading-5 text-slate-500">
                Source: {panel.source}
              </p>
            </div>
          ))}
        </section>

        {(params.credit_success || params.credit_error || params.dva_success || params.dva_error) && (
          <section
            className={`rounded-3xl border p-5 text-sm leading-6 ${
              params.credit_success || params.dva_success
                ? "border-emerald-200 bg-emerald-50 text-emerald-900"
                : "border-red-200 bg-red-50 text-red-900"
            }`}
          >
            {params.credit_success ??
              params.dva_success ??
              params.credit_error ??
              params.dva_error}
          </section>
        )}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Apply importer credit</h2>
              <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">
                Staff-only action using the confirmed backend RPC. This does not
                reconcile DVA/card lines and does not create DVA funding matches.
              </p>
            </div>
            <span className="rounded-full bg-amber-50 px-3 py-1 text-sm font-semibold text-amber-700">
              Credit only
            </span>
          </div>

          {creditCandidates.length === 0 ? (
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
              No funding rows available for credit application.
            </div>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">Order</th>
                    <th className="px-4 py-3 font-semibold">Auth</th>
                    <th className="px-4 py-3 font-semibold">Status</th>
                    <th className="px-4 py-3 font-semibold">Gap</th>
                    <th className="px-4 py-3 font-semibold">Available credit</th>
                    <th className="px-4 py-3 font-semibold">Apply</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {creditCandidates.map((candidate) => (
                    <tr key={candidate.orderId || candidate.orderRef}>
                      <td className="px-4 py-3 align-top font-medium text-slate-900">
                        {candidate.orderRef || "—"}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        {candidate.paymentAuthId || "—"}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        {candidate.status || "—"}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        £{candidate.gap.toFixed(2)}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        £{candidate.availableCredit.toFixed(2)}
                      </td>
                      <td className="px-4 py-3 align-top">
                        <form
                          action={applyImporterCreditAction}
                          className="flex min-w-64 gap-2"
                        >
                          <input
                            type="hidden"
                            name="importer_id"
                            value={candidate.importerId}
                          />
                          <input
                            type="hidden"
                            name="order_id"
                            value={candidate.orderId}
                          />
                          <input
                            name="amount_gbp"
                            type="number"
                            step="0.01"
                            min="0.01"
                            max={
                              candidate.maxApplyAmount > 0
                                ? candidate.maxApplyAmount
                                : undefined
                            }
                            defaultValue={
                              candidate.maxApplyAmount > 0
                                ? candidate.maxApplyAmount.toFixed(2)
                                : ""
                            }
                            disabled={!candidate.canApply}
                            className="w-28 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100"
                          />
                          <button
                            type="submit"
                            disabled={!candidate.canApply}
                            className="rounded-xl bg-sky-600 px-3 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300"
                          >
                            Apply
                          </button>
                        </form>
                        {!candidate.canApply && (
                          <p className="mt-2 text-xs text-slate-500">
                            {candidate.alreadyFunded
                              ? "No funding gap."
                              : candidate.availableCredit <= 0
                                ? "No available credit."
                                : "Cannot apply credit."}
                          </p>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Reconcile DVA funding to order</h2>
              <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">
                Staff-only action using the staff wrapper RPC
                <code className="mx-1 rounded bg-slate-100 px-1 py-0.5">
                  staff_reconcile_dva_line_to_order
                </code>
                from the DVA review worklist suggestions.
              </p>
            </div>
            <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-700">
              Staff only
            </span>
          </div>

          {dvaReconcileCandidates.length === 0 ? (
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
              No DVA worklist rows are currently available for reconciliation.
            </div>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">DVA line</th>
                    <th className="px-4 py-3 font-semibold">Suggested order</th>
                    <th className="px-4 py-3 font-semibold">Line amount</th>
                    <th className="px-4 py-3 font-semibold">Gap remaining</th>
                    <th className="px-4 py-3 font-semibold">Reconcile</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {dvaReconcileCandidates.map((candidate) => (
                    <tr key={candidate.dvaStatementLineId}>
                      <td className="px-4 py-3 align-top font-mono text-xs text-slate-700">
                        {candidate.dvaStatementLineId}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        {candidate.orderRef || candidate.orderId || "—"}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        £{candidate.amountGbp.toFixed(2)}
                      </td>
                      <td className="px-4 py-3 align-top text-slate-700">
                        {candidate.gap === null ? "—" : `£${candidate.gap.toFixed(2)}`}
                      </td>
                      <td className="px-4 py-3 align-top">
                        {candidate.alreadyReconciled ? (
                          <p className="text-xs text-slate-500">
                            Already reconciled — no action available.
                          </p>
                        ) : (
                          <>
                            <form
                              action={reconcileDvaLineToOrderAction}
                              className="flex min-w-[28rem] flex-wrap items-center gap-2"
                            >
                              <input
                                type="hidden"
                                name="dva_statement_line_id"
                                value={candidate.dvaStatementLineId}
                              />
                              <input type="hidden" name="order_id" value={candidate.orderId} />
                              <input
                                type="hidden"
                                name="match_suggestion_id"
                                value={candidate.matchSuggestionId}
                              />
                              <input
                                type="hidden"
                                name="gap_remaining_gbp"
                                value={candidate.gap ?? ""}
                              />
                              <input
                                name="reconciled_gbp_amount"
                                type="number"
                                step="0.01"
                                min="0.01"
                                defaultValue={candidate.amountGbp.toFixed(2)}
                                disabled={!candidate.canReconcile}
                                className="w-32 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100"
                              />
                              <label className="inline-flex items-center gap-2 text-xs text-slate-700">
                                <input
                                  type="checkbox"
                                  name="confirm_overfunding"
                                  value="yes"
                                  disabled={!candidate.canReconcile}
                                />
                                Allow overfunding if amount exceeds gap
                              </label>
                              <input
                                name="notes"
                                type="text"
                                placeholder="Notes (optional)"
                                disabled={!candidate.canReconcile}
                                className="w-44 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100"
                              />
                              <button
                                type="submit"
                                disabled={!candidate.canReconcile}
                                className="rounded-xl bg-sky-600 px-3 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300"
                              >
                                Reconcile DVA
                              </button>
                            </form>
                            {!candidate.canReconcile && (
                              <p className="mt-2 text-xs text-slate-500">
                                Missing suggested order, positive amount, or funding gap.
                              </p>
                            )}
                          </>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Funding diagnostics</h2>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            This section tells us whether the live funding position view exposes
            enough columns for action wiring. If useful columns are missing, we
            do not invent them in the UI; we verify the backend contract first.
          </p>

          {fundingPosition?.error ? (
            <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              Funding position diagnostics unavailable: {fundingPosition.error}
            </div>
          ) : (
            <div className="mt-5 grid gap-4 lg:grid-cols-2">
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="font-semibold">Available order funding columns</h3>
                <p className="mt-2 text-sm leading-6 text-slate-600">
                  {fundingPositionColumns.length > 0
                    ? fundingPositionColumns.join(", ")
                    : "No rows returned, so columns cannot be inferred from the UI response yet."}
                </p>
              </div>
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="font-semibold">Missing useful action columns</h3>
                <p className="mt-2 text-sm leading-6 text-slate-600">
                  {missingUsefulFundingColumns.length > 0
                    ? missingUsefulFundingColumns.join(", ")
                    : "None detected from this response."}
                </p>
              </div>
            </div>
          )}
        </section>

        {results.map((panel) => {
          const columns = visibleColumns(panel.source, panel.rows);
          const available = allColumns(panel.rows);

          return (
            <section
              key={panel.source}
              className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"
            >
              <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">{panel.title}</h2>
                  <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-600">
                    {panel.description}
                  </p>
                  <div className="mt-2 flex flex-wrap gap-2 text-xs text-slate-500">
                    <span>Source: {panel.source}</span>
                    <span>•</span>
                    <span>{panel.role}</span>
                  </div>
                </div>
                <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-600">
                  {panel.error ? "Unavailable" : `${panel.rows.length} rows`}
                </span>
              </div>

              {panel.error ? (
                <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
                  Could not read this source yet: {panel.error}
                </div>
              ) : panel.rows.length === 0 ? (
                <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
                  No rows returned. This can be correct if there is no current work in this queue.
                </div>
              ) : (
                <>
                  <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
                    <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                      <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          {columns.map((column) => (
                            <th key={column} className="px-4 py-3 font-semibold">
                              {column.replaceAll("_", " ")}
                            </th>
                          ))}
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100 bg-white">
                        {panel.rows.map((row, index) => (
                          <tr key={`${panel.source}-${index}`}>
                            {columns.map((column) => (
                              <td
                                key={column}
                                className="max-w-xs px-4 py-3 align-top text-slate-700"
                              >
                                {formatValue(row[column])}
                              </td>
                            ))}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>

                  <details className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
                    <summary className="cursor-pointer font-semibold text-slate-900">
                      Show available columns for {panel.source}
                    </summary>
                    <p className="mt-3 leading-6">{available.join(", ")}</p>
                  </details>
                </>
              )}
            </section>
          );
        })}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Funding controls boundary</h2>
          <p className="mt-2">
            Apply Credit is wired through a confirmed RPC, and DVA reconciliation
            is wired through the confirmed staff wrapper. Importer-facing funding
            controls remain out of scope.
          </p>
        </section>
      </div>
    </main>
  );
}
