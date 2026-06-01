import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
const UNFINISHED_STATUSES = new Set([
  "platform_calculated",
  "dry_run_validated",
  "dry_run_failed",
  "admin_approved",
  "posting_to_sage",
  "failed_retryable",
  "failed_terminal",
]);
const POSTED_STATUSES = new Set(["posted_to_sage", "included_in_sage_return"]);

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function num(value: unknown): number {
  const parsed = Number(text(value).replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function gbp(value: unknown): string {
  return money.format(num(value));
}

function pretty(value: unknown): string {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function dateTime(value: unknown): string {
  const raw = text(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short" }).format(parsed);
}

function short(value: unknown): string {
  const raw = text(value);
  return raw.length > 18 ? `${raw.slice(0, 10)}…${raw.slice(-6)}` : raw || "—";
}

function signedAmount(journal: Row): number {
  const value = Math.abs(num(journal.amount_gbp));
  return text(journal.direction) === "decrease" ? -value : value;
}

function badge(status: string) {
  if (POSTED_STATUSES.has(status)) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (UNFINISHED_STATUSES.has(status)) return "border-amber-200 bg-amber-50 text-amber-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function Metric({ label, value, note, tone = "neutral" }: { label: string; value: string; note: string; tone?: "neutral" | "ok" | "warn" }) {
  const klass = tone === "ok" ? "border-emerald-200 bg-emerald-50 text-emerald-900" : tone === "warn" ? "border-amber-200 bg-amber-50 text-amber-900" : "border-slate-200 bg-white text-slate-900";
  return (
    <div className={`rounded-2xl border p-4 shadow-sm ${klass}`}>
      <p className="text-xs font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-2 text-xs leading-5 opacity-85">{note}</p>
    </div>
  );
}

export default async function VatSageEvidencePackPage({ params }: any) {
  const routeParams = params ? await params : {};
  const runId = text(routeParams?.return_run_id);
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect(`/internal/accounting-vat/returns/${runId}`);

  const { data: runRaw, error: runError } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, locked_at, expected_box1_gbp, expected_box4_gbp, expected_box5_gbp, expected_box6_gbp, expected_box7_gbp, blockers_summary_json")
    .eq("id", runId)
    .maybeSingle();
  const run = (runRaw ?? {}) as Row;

  const { data: journalsRaw, error: journalsError } = await db
    .from("vat_return_adjustment_journals")
    .select("id, vat_return_run_id, adjustment_type, target_box, direction, amount_gbp, status, endpoint_path, method, payload_hash, idempotency_key, sage_business_id, sage_journal_id, sage_journal_ref, posted_at, approved_at, last_error, created_at")
    .eq("vat_return_run_id", runId)
    .order("target_box", { ascending: true })
    .order("direction", { ascending: true })
    .order("created_at", { ascending: true });
  const journals = (journalsRaw ?? []) as Row[];
  const journalIds = journals.map((journal) => text(journal.id)).filter(Boolean);
  const idempotencyKeys = journals.map((journal) => text(journal.idempotency_key)).filter(Boolean);

  let lines: Row[] = [];
  if (journalIds.length > 0) {
    const { data: lineRows } = await db
      .from("vat_return_adjustment_journal_lines")
      .select("id, vat_return_adjustment_journal_id, line_no, line_role, account_role, sage_ledger_account_id, sage_ledger_account_display, debit_amount_gbp, credit_amount_gbp, include_on_tax_return, target_box")
      .in("vat_return_adjustment_journal_id", journalIds)
      .order("line_no", { ascending: true });
    lines = (lineRows ?? []) as Row[];
  }

  let requestLogs: Row[] = [];
  if (idempotencyKeys.length > 0) {
    const { data: requestRows } = await db
      .from("sage_api_request_log")
      .select("id, idempotency_key, endpoint_path, http_method, request_kind, request_payload_hash, created_at")
      .in("idempotency_key", idempotencyKeys)
      .order("created_at", { ascending: false });
    requestLogs = (requestRows ?? []) as Row[];
  }

  const requestLogIds = requestLogs.map((row) => text(row.id)).filter(Boolean);
  let responseLogs: Row[] = [];
  if (requestLogIds.length > 0) {
    const { data: responseRows } = await db
      .from("sage_api_response_log")
      .select("id, request_log_id, http_status, success_yn, sage_object_type, sage_object_id, sage_reference, error_code, error_message, duration_ms, created_at")
      .in("request_log_id", requestLogIds)
      .order("created_at", { ascending: false });
    responseLogs = (responseRows ?? []) as Row[];
  }

  const activeJournals = journals.filter((journal) => text(journal.status) !== "reversed");
  const unfinished = activeJournals.filter((journal) => UNFINISHED_STATUSES.has(text(journal.status)));
  const posted = activeJournals.filter((journal) => POSTED_STATUSES.has(text(journal.status)));
  const netByBox = activeJournals.reduce<Record<string, number>>((acc, journal) => {
    const key = text(journal.target_box) || "none";
    acc[key] = (acc[key] ?? 0) + signedAmount(journal);
    return acc;
  }, {});
  const balancingNet = lines.reduce((sum, line) => text(line.line_role) === "balancing_line" ? sum + num(line.debit_amount_gbp) - num(line.credit_amount_gbp) : sum, 0);
  const vatLineFailures = lines.filter((line) => text(line.line_role) === "vat_box_line" && text(line.include_on_tax_return) !== "true").length;
  const balanceLineFailures = lines.filter((line) => text(line.line_role) === "balancing_line" && text(line.include_on_tax_return) !== "false").length;
  const closeDecision = activeJournals.length > 0 && unfinished.length === 0 ? "Ready / all journals final" : activeJournals.length === 0 ? "No adjustment journals" : "Keep open / unfinished journals remain";

  const linesByJournal = new Map<string, Row[]>();
  for (const line of lines) {
    const id = text(line.vat_return_adjustment_journal_id);
    linesByJournal.set(id, [...(linesByJournal.get(id) ?? []), line]);
  }
  const requestByKey = new Map<string, Row>();
  for (const row of requestLogs) requestByKey.set(text(row.idempotency_key), row);
  const responseByRequest = new Map<string, Row>();
  for (const row of responseLogs) responseByRequest.set(text(row.request_log_id), row);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-vat/returns/${runId}?tab=journals`} className="text-sm font-semibold text-sky-600">← Back to VAT return journals</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT journal evidence pack</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Sage posting readiness and audit trail</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">Admin-only control pack showing platform adjustment journals, Sage /journals evidence, VAT-box inclusion, balancing-line exclusion, and return close readiness.</p>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold text-slate-600">
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1">Run: {text(run.run_ref) || short(run.id)}</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1">Period: {text(run.return_period_label) || `${text(run.period_start_date)} → ${text(run.period_end_date)}`}</span>
            <span className={`rounded-full border px-3 py-1 ${badge(text(run.status))}`}>Status: {pretty(run.status)}</span>
          </div>
        </section>

        {runError ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Run read error: {runError.message}</p> : null}
        {journalsError ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Journal read error: {journalsError.message}</p> : null}

        <section className="grid gap-4 md:grid-cols-4">
          <Metric label="Adjustment journals" value={String(activeJournals.length)} note="Active journals, excluding reversed rows." tone={activeJournals.length > 0 ? "ok" : "neutral"} />
          <Metric label="Posted to Sage" value={`${posted.length}/${activeJournals.length}`} note="Posted or included in Sage return." tone={posted.length === activeJournals.length && activeJournals.length > 0 ? "ok" : "warn"} />
          <Metric label="Unfinished" value={String(unfinished.length)} note="Calculated, validated, approved, posting, or failed." tone={unfinished.length === 0 ? "ok" : "warn"} />
          <Metric label="Close decision" value={unfinished.length === 0 ? "Safe" : "Hold"} note={closeDecision} tone={unfinished.length === 0 ? "ok" : "warn"} />
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <Metric label="VAT line inclusion failures" value={String(vatLineFailures)} note="VAT-box lines must be included on tax return." tone={vatLineFailures === 0 ? "ok" : "warn"} />
          <Metric label="Balancing line exclusion failures" value={String(balanceLineFailures)} note="Suspense/balancing lines must be excluded from tax return." tone={balanceLineFailures === 0 ? "ok" : "warn"} />
          <Metric label="Balancing net" value={gbp(balancingNet)} note="Should net to nil when paired adjustments complete." tone={Math.abs(balancingNet) < 0.005 ? "ok" : "warn"} />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Box-level net adjustment</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">This is the platform-side net of active adjustment journals by target VAT box. A paired increase/decrease test should net to nil.</p>
          <div className="mt-4 grid gap-3 md:grid-cols-4">
            {Object.keys(netByBox).length === 0 ? <p className="text-sm text-slate-500">No adjustment journals found.</p> : Object.entries(netByBox).map(([box, value]) => (
              <div key={box} className={`rounded-2xl border p-4 ${Math.abs(value) < 0.005 ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}>
                <p className="text-xs font-bold uppercase tracking-wide text-slate-500">{box === "none" ? "No box" : `Box ${box}`}</p>
                <p className="mt-1 text-2xl font-extrabold">{gbp(value)}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Journal evidence</h2>
          <div className="mt-5 overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
              <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Journal</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Box / direction</th><th className="px-3 py-2">Amount</th><th className="px-3 py-2">Sage ref</th><th className="px-3 py-2">Posted</th><th className="px-3 py-2">API evidence</th></tr></thead>
              <tbody className="divide-y divide-slate-100">
                {journals.map((journal) => {
                  const request = requestByKey.get(text(journal.idempotency_key));
                  const response = request ? responseByRequest.get(text(request.id)) : undefined;
                  return (
                    <tr key={text(journal.id)}>
                      <td className="px-3 py-2"><Link href={`/internal/accounting-vat/journals/${text(journal.id)}`} className="font-semibold text-sky-700 hover:underline">{short(journal.id)}</Link><p className="mt-1 text-xs text-slate-500">{pretty(journal.adjustment_type)}</p></td>
                      <td className="px-3 py-2"><span className={`rounded-full border px-2 py-1 text-xs font-bold ${badge(text(journal.status))}`}>{pretty(journal.status)}</span></td>
                      <td className="px-3 py-2">Box {text(journal.target_box) || "—"}<p className="text-xs text-slate-500">{pretty(journal.direction)}</p></td>
                      <td className="px-3 py-2 font-semibold">{gbp(journal.amount_gbp)}</td>
                      <td className="px-3 py-2"><p className="break-all font-semibold">{text(journal.sage_journal_ref) || "—"}</p><p className="mt-1 break-all text-xs text-slate-500">{text(journal.sage_journal_id) || "No Sage ID"}</p></td>
                      <td className="px-3 py-2">{dateTime(journal.posted_at)}</td>
                      <td className="px-3 py-2"><p className="text-xs">Request: {request ? "yes" : "—"}</p><p className="text-xs">Response: {response ? `${text(response.http_status)} / ${text(response.success_yn)}` : "—"}</p></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Line inclusion / exclusion proof</h2>
          <div className="mt-5 overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
              <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Journal</th><th className="px-3 py-2">Line</th><th className="px-3 py-2">Role</th><th className="px-3 py-2">Account</th><th className="px-3 py-2">Debit</th><th className="px-3 py-2">Credit</th><th className="px-3 py-2">Tax return</th><th className="px-3 py-2">Target box</th></tr></thead>
              <tbody className="divide-y divide-slate-100">
                {journals.flatMap((journal) => (linesByJournal.get(text(journal.id)) ?? []).map((line) => (
                  <tr key={text(line.id)}>
                    <td className="px-3 py-2 font-semibold">{short(journal.id)}</td>
                    <td className="px-3 py-2">{text(line.line_no)}</td>
                    <td className="px-3 py-2">{pretty(line.line_role)}</td>
                    <td className="px-3 py-2"><p className="font-semibold">{text(line.sage_ledger_account_display) || "—"}</p><p className="break-all text-xs text-slate-500">{text(line.sage_ledger_account_id) || "No Sage GL ID"}</p></td>
                    <td className="px-3 py-2 font-semibold">{gbp(line.debit_amount_gbp)}</td>
                    <td className="px-3 py-2 font-semibold">{gbp(line.credit_amount_gbp)}</td>
                    <td className="px-3 py-2"><span className={`rounded-full border px-2 py-1 text-xs font-bold ${text(line.include_on_tax_return) === "true" ? "border-sky-200 bg-sky-50 text-sky-800" : "border-slate-200 bg-slate-50 text-slate-700"}`}>{text(line.include_on_tax_return) === "true" ? "Included" : "Excluded"}</span></td>
                    <td className="px-3 py-2">{text(line.target_box) ? `Box ${text(line.target_box)}` : "—"}</td>
                  </tr>
                ))) }
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
