import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { generateNextSageVatDraftRunAction } from "./actions";
import VatWorkflowPreview from "./VatWorkflowPreview";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
const money = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});
const activeStatuses = [
  "draft",
  "calculated",
  "admin_review_required",
  "blocked",
  "admin_approved",
  "sage_adjustment_journals_pending",
  "sage_adjustment_journals_posted",
  "sage_return_review_required",
  "sage_return_submitted",
  "mismatch_needs_admin_review",
  "reopened_for_correction",
];

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}
function cleanDisplay(value: unknown): string {
  return text(value)
    .replaceAll("([object Object])", "")
    .replaceAll("[object Object]", "")
    .replace(/\s+—\s*$/g, "")
    .replace(/\s+/g, " ")
    .trim();
}
function amount(value: unknown): string {
  const parsed = Number(cleanDisplay(value).replace(/,/g, ""));
  return money.format(Number.isFinite(parsed) ? parsed : 0);
}
function date(value: unknown): string {
  const raw = cleanDisplay(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(parsed);
}
function label(value: unknown, max = 58): string {
  const raw = cleanDisplay(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

export default async function VatDashboardPage({ searchParams }: any = {}) {
  const params = searchParams ? await searchParams : {};
  const vatError = text(params?.vatError);
  const supabase = await createClient();
  const db = supabase as any;
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal");

  const { data: runsData, error: runsError } = await db
    .from("vat_return_runs")
    .select(
      "id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box6_gbp",
    )
    .in("status", activeStatuses)
    .not("run_ref", "like", "VAT-JOURNAL-TEST-%")
    .not("return_period_label", "ilike", "%test only%")
    .order("period_start_date", { ascending: true })
    .order("created_at", { ascending: true })
    .limit(25);

  const { data: blockersData, error: blockersError } = await db
    .from("vat_return_blockers")
    .select(
      "id, vat_return_run_id, blocker_code, severity, status, message, required_action",
    )
    .eq("status", "open")
    .order("created_at", { ascending: false })
    .limit(12);

  const { count: journalCount } = await db
    .from("vat_return_adjustment_journals")
    .select("*", { count: "exact", head: true });
  const runs = (runsData ?? []) as Row[];
  const blockers = (blockersData ?? []) as Row[];

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">
            ← Back to internal dashboard
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
            Admin-only VAT Return Workbench
          </p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">
                VAT control dashboard
              </h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Control room for active VAT return packs. Superseded packs are
                hidden from this active list.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">
                {label((staff as Row).full_name) || "Admin"}
              </div>
              <div>{label((staff as Row).role_type)}</div>
            </div>
          </div>
        </section>

        {vatError ? (
          <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
            VAT action failed: {vatError}
          </div>
        ) : null}

        <section className="grid gap-4 md:grid-cols-3">
          <Stat
            title="Active packs"
            value={String(runs.length)}
            detail="Excludes superseded June/July-style drafts."
          />
          <Stat
            title="Open blockers"
            value={String(blockers.length)}
            detail="Resolve before approval, posting or lock."
            warn={blockers.length > 0}
          />
          <Stat
            title="Adjustment journals"
            value={String(journalCount ?? 0)}
            detail="Journal only the Sage gap."
          />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold tracking-tight">
            Generate VAT Return Pack
          </h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Creates the next permitted return pack only when no earlier active
            return pack is still open.
          </p>
          <form action={generateNextSageVatDraftRunAction} className="mt-4">
            <button className="rounded-xl bg-slate-950 px-4 py-3 text-sm font-semibold text-white">
              Generate next VAT return pack
            </button>
          </form>
        </section>

        <VatWorkflowPreview />

        {runsError ? (
          <ReadError label="VAT packs" message={runsError.message} />
        ) : (
          <Runs rows={runs} />
        )}
        {blockersError ? (
          <ReadError label="Blockers" message={blockersError.message} />
        ) : (
          <Blockers rows={blockers} />
        )}
      </div>
    </main>
  );
}

function Stat({
  title,
  value,
  detail,
  warn = false,
}: {
  title: string;
  value: string;
  detail: string;
  warn?: boolean;
}) {
  return (
    <div
      className={`rounded-2xl border p-4 shadow-sm ${warn ? "border-amber-200 bg-amber-50 text-amber-900" : "border-sky-200 bg-sky-50 text-sky-900"}`}
    >
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">
        {title}
      </p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-2 text-xs leading-5 opacity-90">{detail}</p>
    </div>
  );
}
function ReadError({ label, message }: { label: string; message: string }) {
  return (
    <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
      {label} read error: {message}
    </div>
  );
}
function Runs({ rows }: { rows: Row[] }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold tracking-tight">
          Active VAT return packs
        </h2>
        <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">
          {rows.length} shown
        </span>
      </div>
      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
          <thead className="text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2">Run</th>
              <th className="px-3 py-2">Period</th>
              <th className="px-3 py-2">Start</th>
              <th className="px-3 py-2">End</th>
              <th className="px-3 py-2">Status</th>
              <th className="px-3 py-2">Box 6</th>
              <th className="px-3 py-2">Action</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.length === 0 ? (
              <tr>
                <td colSpan={7} className="px-3 py-5 text-slate-500">
                  No active VAT return packs.
                </td>
              </tr>
            ) : (
              rows.map((row) => (
                <tr key={text(row.id)}>
                  <td className="px-3 py-2">{label(row.run_ref, 24)}</td>
                  <td className="px-3 py-2">
                    {label(row.return_period_label)}
                  </td>
                  <td className="px-3 py-2">{date(row.period_start_date)}</td>
                  <td className="px-3 py-2">{date(row.period_end_date)}</td>
                  <td className="px-3 py-2">{label(row.status, 28)}</td>
                  <td className="px-3 py-2">{amount(row.expected_box6_gbp)}</td>
                  <td className="px-3 py-2">
                    <div className="flex flex-wrap gap-2">
                      <Link
                        className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-800"
                        href={`/internal/accounting-vat/returns/${text(row.id)}`}
                      >
                        Open pack
                      </Link>
                      <Link
                        className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs font-bold text-emerald-800"
                        href={`/internal/accounting-vat/returns/${text(row.id)}/sage-draft-import`}
                      >
                        Import Sage draft
                      </Link>
                    </div>
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
function Blockers({ rows }: { rows: Row[] }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold tracking-tight">
          Open VAT blockers
        </h2>
        <Link
          href="/internal/accounting-vat/blockers"
          className="text-sm font-semibold text-sky-700"
        >
          Open blocker page →
        </Link>
      </div>
      <div className="mt-4 grid gap-3">
        {rows.length === 0 ? (
          <p className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">
            No open blockers.
          </p>
        ) : (
          rows.map((row) => (
            <div
              key={text(row.id)}
              className="rounded-2xl border border-slate-200 bg-slate-50 p-4"
            >
              <div className="flex flex-wrap justify-between gap-3">
                <p className="font-semibold text-slate-950">
                  {label(row.blocker_code, 70)}
                </p>
                {text(row.vat_return_run_id) ? (
                  <Link
                    href={`/internal/accounting-vat/returns/${text(row.vat_return_run_id)}`}
                    className="text-sm font-semibold text-sky-700"
                  >
                    Open pack
                  </Link>
                ) : null}
              </div>
              <p className="mt-2 text-sm text-slate-700">
                {label(row.message, 150)}
              </p>
              <p className="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
                {label(row.severity, 20)} · {label(row.status, 20)}
              </p>
            </div>
          ))
        )}
      </div>
    </section>
  );
}
