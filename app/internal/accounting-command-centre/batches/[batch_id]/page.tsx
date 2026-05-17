import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
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

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 42) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function statusTone(value: unknown): Tone {
  const raw = text(value);
  if (["included", "validated", "posted", "draft", "local_validated_pending_sage_dry_run", "dry_run_validated"].includes(raw)) return "complete";
  if (["excluded", "blocked", "failed_retryable", "failed_terminal", "dry_run_failed"].includes(raw)) return "blocked";
  if (["posting", "posting_disabled_until_sage_connection_tested", "not_dry_run_validated"].includes(raw)) return "action";
  if (["cancelled", "excluded_before_validation"].includes(raw)) return "review";
  return "muted";
}

function Chip({ value }: { value: unknown }) {
  return <span className={`inline-flex max-w-[190px] truncate rounded-full border px-2 py-0.5 text-[10px] font-bold leading-4 ${toneClass(statusTone(value))}`}>{pretty(value)}</span>;
}

function Kpi({ label, value, detail, tone }: { label: string; value: string; detail?: string; tone: Tone }) {
  return (
    <div className={`min-w-[128px] rounded-xl border px-3 py-2 ${toneClass(tone)}`}>
      <p className="text-[10px] font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-0.5 truncate text-lg font-extrabold leading-6">{value}</p>
      {detail ? <p className="mt-0.5 truncate text-[10px] leading-4 opacity-80">{detail}</p> : null}
    </div>
  );
}

export default async function PostingBatchDetailPage({ params }: { params: Promise<{ batch_id: string }> | { batch_id: string } }) {
  const resolvedParams = await Promise.resolve(params);
  const batchId = resolvedParams.batch_id;

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);
  if (!canAccess) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl rounded-3xl border border-amber-200 bg-amber-50 p-6 text-amber-900 shadow-sm">
          <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
          <h1 className="mt-5 text-3xl font-bold tracking-tight">Posting batch access required</h1>
          <p className="mt-3 text-sm leading-6">This batch detail is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
        </div>
      </main>
    );
  }

  const { data, error } = await (supabase as any).rpc("internal_sage_posting_batch_detail_v1", {
    p_batch_id: batchId,
  });

  const rows = ((data ?? []) as Row[]).filter((row) => text(row.batch_id));
  const first = rows[0] ?? {};
  const summary = asObject(first.batch_summary);
  const includedRows = rows.filter((row) => text(row.posting_status) !== "excluded");
  const excludedRows = rows.filter((row) => text(row.posting_status) === "excluded");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div className="min-w-0">
              <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
              <p className="mt-4 text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Posting batch detail</p>
              <h1 className="mt-1 truncate text-3xl font-semibold tracking-tight sm:text-4xl">{text(first.batch_ref) || "Posting batch"}</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">Phase 10 local batch lock. Shows included/excluded rows, values, snapshot IDs, idempotency keys and local payload status. Sage posting remains disabled until OAuth and dry-run are proven.</p>
            </div>
            <div className="shrink-0 rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{text(staff.full_name)}</div><div>{text(staff.role_type)}</div></div>
          </div>
          {error ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch detail RPC unavailable: {error.message}. Run the Phase 9/10 migration before testing this page.</p> : null}
          {!error && rows.length === 0 ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">No batch rows found for this batch id.</p> : null}

          <div className="mt-4 overflow-x-auto pb-1">
            <div className="flex min-w-max gap-2">
              <Kpi label="Status" value={pretty(first.status)} detail={`legacy ${pretty(first.batch_status)}`} tone={statusTone(first.status)} />
              <Kpi label="Lane" value={pretty(first.lane)} detail="document mix" tone="review" />
              <Kpi label="Included" value={String(summary.included_count ?? includedRows.length)} detail="locked rows" tone={includedRows.length > 0 ? "complete" : "muted"} />
              <Kpi label="Excluded" value={String(summary.excluded_count ?? excludedRows.length)} detail="skipped rows" tone={excludedRows.length > 0 ? "blocked" : "complete"} />
              <Kpi label="Value" value={gbp(summary.total_included_value ?? first.total_amount_gbp)} detail="included only" tone="complete" />
              <Kpi label="Customer" value={String(summary.customer_sales_count ?? 0)} detail="sales rows" tone={num(summary.customer_sales_count) > 0 ? "complete" : "muted"} />
              <Kpi label="Shipper AP" value={String(summary.shipper_ap_count ?? 0)} detail="AP rows" tone={num(summary.shipper_ap_count) > 0 ? "complete" : "muted"} />
              <Kpi label="Posting" value="Disabled" detail="OAuth + dry-run first" tone="action" />
            </div>
          </div>
        </section>

        <section className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900">
          <p><span className="font-bold">Posting disabled:</span> no Sage API call happens from this page. This is a controlled local lock of ready-to-post frozen snapshots only.</p>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="flex flex-col gap-2 border-b border-slate-100 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Batch rows</h2>
              <p className="mt-1 text-sm text-slate-500">Included and excluded rows are retained for audit. Excluded rows are not posted and do not lock a snapshot for posting.</p>
            </div>
            <p className="text-xs font-semibold text-slate-500">Batch id {batchId}</p>
          </div>
          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1240px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[110px]" />
                <col className="w-[120px]" />
                <col className="w-[150px]" />
                <col className="w-[170px]" />
                <col className="w-[160px]" />
                <col className="w-[90px]" />
                <col className="w-[170px]" />
                <col className="w-[170px]" />
                <col className="w-[300px]" />
              </colgroup>
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 text-left">Status</th>
                  <th className="px-2 py-2 text-left">Lane</th>
                  <th className="px-2 py-2 text-left">Document</th>
                  <th className="px-2 py-2 text-left">Order / ref</th>
                  <th className="px-2 py-2 text-left">Counterparty</th>
                  <th className="px-2 py-2 text-right">Amount</th>
                  <th className="px-2 py-2 text-left">Payload validation</th>
                  <th className="px-2 py-2 text-left">Snapshot / idem</th>
                  <th className="px-2 py-2 text-left">Reason / error</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? <tr><td colSpan={9} className="px-3 py-8 text-center text-sm text-slate-500">No rows.</td></tr> : rows.map((row) => (
                  <tr key={text(row.row_id) || `${text(row.snapshot_id)}-${text(row.source_id)}`} className="align-top hover:bg-slate-50">
                    <td className="px-2 py-2"><Chip value={row.posting_status} /></td>
                    <td className="px-2 py-2"><p className="truncate font-bold text-slate-950">{pretty(row.document_lane)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{pretty(row.sage_object_type)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-bold text-slate-950">{pretty(row.document_type)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{pretty(row.source_table)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-mono text-[11px] font-bold text-slate-950">{text(row.order_ref) || "—"}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{short(row.reference_text, 44)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-semibold text-slate-900">{text(row.counterparty_name) || "—"}</p></td>
                    <td className="px-2 py-2 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}<p className="text-[11px] font-normal text-slate-500">{text(row.currency_code) || "GBP"}</p></td>
                    <td className="px-2 py-2"><Chip value={row.payload_validation_status} /></td>
                    <td className="px-2 py-2"><p className="truncate font-mono text-[11px] font-bold text-slate-950" title={text(row.snapshot_id)}>{short(row.snapshot_id, 28)}</p><p className="mt-0.5 truncate font-mono text-[11px] text-slate-500" title={text(row.idempotency_key)}>{short(row.idempotency_key, 32)}</p></td>
                    <td className="px-2 py-2"><p className="line-clamp-3 text-[11px] font-semibold leading-4 text-slate-600">{text(row.exclusion_reason) || text(row.error_message) || "—"}</p></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
