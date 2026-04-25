import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type DataRow = Record<string, unknown>;

type PanelResult = {
  title: string;
  description: string;
  source: string;
  rows: DataRow[];
  error: string | null;
};

const panels = [
  {
    title: "DVA review worklist",
    description: "Bank/card lines that need staff review, matching, or allocation.",
    source: "day2_dva_review_worklist_vw",
  },
  {
    title: "Order funding positions",
    description: "Orders with their funding position, gaps, and overfunding state.",
    source: "order_funding_position_vw",
  },
  {
    title: "Importer credit balances",
    description: "Available importer credit that can be applied to future orders.",
    source: "importer_balance_vw",
  },
  {
    title: "Recent DVA lines",
    description: "Raw DVA statement lines for funding traceability.",
    source: "dva_statement_lines",
  },
  {
    title: "Recent funding events",
    description: "Immutable funding events created by reconciliation, credit, or adjustments.",
    source: "order_funding_events",
  },
] as const;

function formatValue(value: unknown) {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number") return value.toLocaleString("en-GB");
  if (typeof value === "string") {
    if (value.length > 70) return `${value.slice(0, 67)}...`;
    return value;
  }
  return JSON.stringify(value);
}

function preferredColumns(rows: DataRow[]) {
  const preferred = [
    "order_ref",
    "importer_name",
    "company_name",
    "trading_name",
    "payment_auth_id",
    "auth_id_ref",
    "reference_raw",
    "match_status",
    "status",
    "event_type",
    "amount_gbp",
    "amount_gbp_equivalent",
    "funded_total_gbp",
    "funding_gap_gbp",
    "available_credit_gbp",
    "created_at",
    "reconciled_at",
  ];

  const present = new Set(rows.flatMap((row) => Object.keys(row)));
  const selected = preferred.filter((key) => present.has(key));

  if (selected.length > 0) return selected.slice(0, 7);
  return Object.keys(rows[0] ?? {}).slice(0, 7);
}

async function readPanel(source: string): Promise<Omit<PanelResult, "title" | "description">> {
  const supabase = await createClient();
  const { data, error } = await supabase.from(source).select("*").limit(8);

  return {
    source,
    rows: (data ?? []) as DataRow[],
    error: error?.message ?? null,
  };
}

export default async function InternalFundingPage() {
  const results = await Promise.all(
    panels.map(async (panel) => ({
      ...panel,
      ...(await readPanel(panel.source)),
    }))
  );

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">
            ← Back to internal dashboard
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
            Day 2 live read-only wiring
          </p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">
            Funding queue
          </h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Read-only operational view for DVA/card lines, funding positions,
            importer balances, and immutable funding events. Action buttons are
            deliberately held back until the data shape is confirmed on live.
          </p>
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          {results.slice(0, 3).map((panel) => (
            <div key={panel.source} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <p className="text-sm text-slate-500">{panel.title}</p>
              <p className="mt-2 text-3xl font-semibold">{panel.error ? "—" : panel.rows.length}</p>
              <p className="mt-3 text-xs leading-5 text-slate-500">Source: {panel.source}</p>
            </div>
          ))}
        </section>

        {results.map((panel) => {
          const columns = preferredColumns(panel.rows);

          return (
            <section key={panel.source} className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
              <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">{panel.title}</h2>
                  <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-600">{panel.description}</p>
                  <p className="mt-2 text-xs text-slate-500">Source: {panel.source}</p>
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
                            <td key={column} className="max-w-xs px-4 py-3 align-top text-slate-700">
                              {formatValue(row[column])}
                            </td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>
          );
        })}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Action wiring held back deliberately</h2>
          <p className="mt-2">
            The next step is to confirm the live data shown here, then add staff-only actions for reconciliation, match acceptance, and importer credit application. No importer-facing user should be able to operate this page.
          </p>
        </section>
      </div>
    </main>
  );
}
