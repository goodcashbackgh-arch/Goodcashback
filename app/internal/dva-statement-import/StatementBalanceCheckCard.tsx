import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

type BalanceLine = {
  sourceRowNumber: string;
  parseStatus: string;
  corrected: boolean;
  ok: boolean;
};

const moneyFormatter = new Intl.NumberFormat("en-GB", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const BALANCE_TOLERANCE = 0.02;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function numberValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function round2(value: number) {
  return Math.round(value * 100) / 100;
}

function money(value: number | null | undefined, ccy: string) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  return `${moneyFormatter.format(value)} ${ccy}`;
}

function statusClass(status: "passed" | "review" | "failed") {
  if (status === "passed") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (status === "review") return "border-amber-200 bg-amber-50 text-amber-900";
  return "border-rose-200 bg-rose-50 text-rose-900";
}

function pillClass(status: "passed" | "review" | "failed") {
  if (status === "passed") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (status === "review") return "bg-amber-100 text-amber-800 ring-amber-200";
  return "bg-rose-100 text-rose-800 ring-rose-200";
}

function getObject(value: unknown) {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    const obj = getObject(current);
    if (!obj) return null;
    current = obj[key];
  }
  return current ?? null;
}

function fieldValue(rawJson: unknown, name: string) {
  return getByPath(rawJson, ["inference", "result", "fields", name, "value"]);
}

function fieldItems(rawJson: unknown, name: string) {
  const items = getByPath(rawJson, ["inference", "result", "fields", name, "items"]);
  return Array.isArray(items) ? items : [];
}

function maskAccount(accountNumber: string) {
  if (!accountNumber) return "—";
  const last4 = accountNumber.slice(-4);
  return `•••• ${last4}`;
}

function isCorrected(rawJson: unknown) {
  return Boolean(getByPath(rawJson, ["_goodcashback_balance_check", "corrected"]));
}

async function resolveBatchId(requestedBatchId: string | null) {
  const supabase = await createClient();
  if (requestedBatchId) return requestedBatchId;

  const { data } = await supabase
    .from("dva_statement_import_batches")
    .select("id")
    .gt("row_count", 0)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  return text((data as Row | null)?.id) || null;
}

export default async function StatementBalanceCheckCard({ importBatchId }: { importBatchId?: string | null }) {
  const supabase = await createClient();
  const selectedBatchId = await resolveBatchId(importBatchId ?? null);
  if (!selectedBatchId) return null;

  const [batchResult, rowsResult] = await Promise.all([
    supabase
      .from("dva_statement_import_batches")
      .select("id, original_filename, source_file_url, detected_file_type, local_ccy, status, row_count, clean_count, error_count, committed_count, committed_at, mindee_statement_raw_json")
      .eq("id", selectedBatchId)
      .maybeSingle(),
    supabase
      .from("dva_statement_import_rows")
      .select("source_row_number, direction, amount_local_ccy, balance_after_local_ccy, parse_status, raw_json")
      .eq("import_batch_id", selectedBatchId)
      .order("source_row_number", { ascending: true }),
  ]);

  const batch = batchResult.data as Row | null;
  const rows = (rowsResult.data ?? []) as unknown as Row[];
  if (!batch || rows.length === 0) return null;

  const rawJson = batch.mindee_statement_raw_json;
  const ccy = text(batch.local_ccy) || "GHS";
  const sourceFileUrl = text(batch.source_file_url);
  const batchStatus = text(batch.status);
  const batchCleanCount = num(batch.clean_count);
  const batchCommittedCount = num(batch.committed_count);
  const batchIsCommitted = batchStatus === "committed" || batchCommittedCount > 0 || Boolean(text(batch.committed_at));
  const openingBalance = numberValue(fieldValue(rawJson, "beginning_balance"));
  const endingBalance = numberValue(fieldValue(rawJson, "ending_balance"));
  const totalDebits = numberValue(fieldValue(rawJson, "total_debits"));
  const totalCredits = numberValue(fieldValue(rawJson, "total_credits"));
  const statementPeriodFrom = text(fieldValue(rawJson, "statement_period_start_date"));
  const statementPeriodTo = text(fieldValue(rawJson, "statement_period_end_date"));
  const accountNumber = text(fieldValue(rawJson, "account_number"));
  const accountHolder = fieldItems(rawJson, "account_holder_names").map((item) => text(getByPath(item, ["value"]))).filter(Boolean).join(", ") || "—";

  let runningBalance = openingBalance;
  const lines: BalanceLine[] = rows.map((row) => {
    const direction = text(row.direction);
    const amount = Math.abs(numberValue(row.amount_local_ccy) ?? 0);
    const extractedBalance = numberValue(row.balance_after_local_ccy);
    const signedAmount = direction === "in" ? amount : -amount;
    const calculatedBalance = runningBalance === null ? null : round2(runningBalance + signedAmount);
    const ok = calculatedBalance !== null && extractedBalance !== null && Math.abs(calculatedBalance - extractedBalance) <= BALANCE_TOLERANCE;
    if (extractedBalance !== null) runningBalance = extractedBalance;
    return {
      sourceRowNumber: text(row.source_row_number),
      parseStatus: text(row.parse_status),
      corrected: isCorrected(row.raw_json),
      ok,
    };
  });

  const rowStatusCleanCount = lines.filter((line) => line.parseStatus === "clean").length;
  const displayedCleanCount = batchIsCommitted ? Math.max(batchCleanCount, batchCommittedCount, rowStatusCleanCount) : rowStatusCleanCount;
  const correctedCount = lines.filter((line) => line.corrected).length;
  const failedBalanceLines = lines.filter((line) => !line.ok).length;
  const calculatedEnding = openingBalance !== null && totalCredits !== null && totalDebits !== null
    ? round2(openingBalance + totalCredits - totalDebits)
    : lines.length
      ? runningBalance
      : openingBalance;
  const endingMatches = calculatedEnding !== null && endingBalance !== null && Math.abs(calculatedEnding - endingBalance) <= BALANCE_TOLERANCE;
  const allRowsClean = displayedCleanCount >= lines.length;
  const status: "passed" | "review" | "failed" = !allRowsClean || failedBalanceLines > 0 || !endingMatches ? "failed" : correctedCount > 0 ? "review" : "passed";
  const statusLabel = batchIsCommitted
    ? status === "passed" ? "COMMITTED" : status === "review" ? "COMMITTED WITH CORRECTIONS" : "COMMITTED — REVIEW SIGNAL"
    : status === "passed" ? "PASSED" : status === "review" ? "PASSED WITH CORRECTIONS" : "NEEDS REVIEW";
  const netMovement = totalCredits !== null && totalDebits !== null ? round2(totalCredits - totalDebits) : null;

  return (
    <section className={`rounded-3xl border p-6 shadow-sm ${statusClass(status)}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium uppercase tracking-[0.18em] opacity-80">Statement control check</p>
          <h2 className="mt-2 text-2xl font-semibold tracking-tight">{batchIsCommitted ? "Committed control summary" : "Summary before commit"}</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 opacity-80">
            {batchIsCommitted
              ? "This batch has already been committed. This card is now a post-commit review signal; matching work sits in the DVA/card workspace."
              : "Header, balance, and row-health summary only. Full transaction review sits in the staged rows section below."}
          </p>
        </div>
        <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${pillClass(status)}`}>{statusLabel}</span>
      </div>

      <div className="mt-5 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Account holder</span><span className="font-semibold">{accountHolder}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Account number</span><span className="font-semibold">{maskAccount(accountNumber)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Extracted period</span><span className="font-semibold">{statementPeriodFrom || "—"} → {statementPeriodTo || "—"}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Batch</span><span className="break-words font-semibold [overflow-wrap:anywhere]">{text(batch.original_filename) || selectedBatchId}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Opening balance</span><span className="font-semibold">{money(openingBalance, ccy)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Credits less debits</span><span className="font-semibold">{money(netMovement, ccy)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Extracted ending</span><span className="font-semibold">{money(endingBalance, ccy)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Calculated ending</span><span className="font-semibold">{money(calculatedEnding, ccy)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Total debits</span><span className="font-semibold">{money(totalDebits, ccy)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Total credits</span><span className="font-semibold">{money(totalCredits, ccy)}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Rows clean</span><span className="font-semibold">{displayedCleanCount}/{lines.length}</span></p>
        <p><span className="block text-xs font-semibold uppercase tracking-wide opacity-70">Corrections / mismatches</span><span className="font-semibold">{correctedCount} corrected · {failedBalanceLines} mismatch</span></p>
      </div>

      <div className="mt-5 flex flex-wrap gap-3">
        {sourceFileUrl ? (
          <a className="rounded-xl bg-white px-4 py-2 text-sm font-semibold ring-1 ring-current" href={sourceFileUrl} target="_blank" rel="noreferrer">
            Open uploaded statement PDF
          </a>
        ) : null}
        <Link className="rounded-xl bg-white px-4 py-2 text-sm font-semibold ring-1 ring-current" href="#staged-statement-rows">
          Review staged rows
        </Link>
        {batchIsCommitted ? (
          <Link className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" href="/internal/dva-reconciliation/workspace">
            Open matching workspace
          </Link>
        ) : null}
      </div>

      {status !== "passed" ? (
        <p className="mt-4 text-sm font-semibold">
          {batchIsCommitted
            ? "This does not reverse the commit. It is a post-commit review signal only; check the staged rows or matching workspace before relying on this batch downstream."
            : status === "review"
              ? "Balance totals passed, but at least one Mindee direction was corrected using balance movement. Review the affected rows before committing."
              : "Balance totals, staged row cleanliness, or row-level balance checks failed. Do not commit this batch until reviewed."}
        </p>
      ) : null}
    </section>
  );
}
