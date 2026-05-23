import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { postCustomerReceiptCashBatchAction } from "../../actions";

type Row = Record<string, unknown>;

type Params = { batch_id: string } | Promise<{ batch_id: string }>;
type SearchParams = Record<string, string | string[] | undefined> | Promise<Record<string, string | string[] | undefined>>;

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });
const outBatchCategories = ["supplier_invoice_payment", "shipper_invoice_payment", "out_purchase_payment"];

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function amount(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) return Number(value) || 0;
  return 0;
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function hasAccountingAccess(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function pretty(value: unknown) {
  return text(value).replaceAll("_", " ") || "—";
}

function short(value: unknown, max = 48) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function messageParam(searchParams: Record<string, string | string[] | undefined>, key: "success" | "error") {
  return text(searchParams[key]);
}

function isPostable(row: Row) {
  return text(row.row_validation_status) === "validated" && ["not_posted", "failed_retryable"].includes(text(row.row_posting_status));
}

function Pill({ value }: { value: unknown }) {
  const raw = text(value);
  const tone = raw.startsWith("failed")
    ? "border-rose-200 bg-rose-50 text-rose-900"
    : raw === "posted" || raw === "posted_needs_review"
      ? "border-sky-200 bg-sky-50 text-sky-900"
      : raw === "posting"
        ? "border-amber-200 bg-amber-50 text-amber-900"
        : "border-emerald-200 bg-emerald-50 text-emerald-900";
  return <span className={`inline-flex rounded-full border px-2 py-0.5 text-[10px] font-bold ${tone}`}>{pretty(value)}</span>;
}

function PayloadBlock({ title, value }: { title: string; value: unknown }) {
  return (
    <details className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs">
      <summary className="cursor-pointer font-bold text-slate-900">{title}</summary>
      <pre className="mt-2 max-h-72 overflow-auto rounded-xl bg-white p-3 text-[11px] leading-5 text-slate-700">{JSON.stringify(value ?? {}, null, 2)}</pre>
    </details>
  );
}

export default async function CashPostingBatchDetailPage({ params, searchParams }: { params: Params; searchParams?: SearchParams }) {
  const resolvedParams = await Promise.resolve(params);
  const resolvedSearchParams = await Promise.resolve(searchParams ?? {});
  const batchId = resolvedParams.batch_id;
  const success = messageParam(resolvedSearchParams, "success");
  const pageError = messageParam(resolvedSearchParams, "error");

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  const canAccess = text(staff.role_type) === "admin" || hasAccountingAccess((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  const { data, error } = await (supabase as any).rpc("internal_cash_posting_batch_detail_v1", { p_batch_id: batchId });
  const rows = (data ?? []) as Row[];
  const first = rows[0] ?? {};
  const batchCategory = text(first.batch_posting_category) || text(first.posting_category);
  const isOutBatch = outBatchCategories.includes(batchCategory);
  const livePostingEnabled = isOutBatch ? process.env.SAGE_LIVE_CASH_OUT_POSTING_ENABLED === "true" : process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
  const postableRows = rows.filter(isPostable);
  const canPost = livePostingEnabled && postableRows.length > 0 && ["validated", "failed", "partially_posted"].includes(text(first.batch_status));
  const batchIntro = isOutBatch
    ? "Posts supplier/shipper OUT payments to Sage, then allocates each payment to the matched posted purchase invoice."
    : "Posts customer/importer IN receipts to Sage as customer receipts on account. Allocation to sales invoices is handled after the receipt exists.";
  const endpointText = isOutBatch ? "POST /purchase_payments, then POST /allocations" : "POST /contact_payments";
  const flagName = isOutBatch ? "SAGE_LIVE_CASH_OUT_POSTING_ENABLED" : "SAGE_LIVE_CASH_POSTING_ENABLED";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <Link href="/internal/accounting-command-centre/cash-posting" className="text-sm font-semibold text-sky-700">← Cash Posting Workbench</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Cash batch detail</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">{text(first.batch_ref) || "Cash batch"}</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">{batchIntro}</p>
          <div className="mt-3 flex flex-wrap gap-2 text-[11px] font-bold">
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">Category: {pretty(batchCategory)}</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Endpoint: {endpointText}</span>
          </div>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {pageError ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{pageError}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch detail unavailable: {error.message}. Run the latest cash batch detail migration.</p> : null}
        </section>

        {rows.length === 0 && !error ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-6 text-sm text-slate-600 shadow-sm">No rows found for this cash batch.</section>
        ) : null}

        {rows.length > 0 ? (
          <>
            <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
              <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-emerald-900"><p className="text-[11px] font-bold uppercase tracking-wide opacity-70">Status</p><p className="mt-1 text-xl font-extrabold">{pretty(first.batch_status)}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Rows</p><p className="mt-1 text-xl font-extrabold">{text(first.batch_row_count)}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Total</p><p className="mt-1 text-xl font-extrabold">{money.format(amount(first.batch_total_amount_gbp))}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Postable rows</p><p className="mt-1 text-xl font-extrabold">{postableRows.length}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Created</p><p className="mt-1 text-xs font-bold">{text(first.batch_created_at)}</p><p className="text-[11px] text-slate-500">{text(first.batch_created_by_name)}</p></div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
              <div className="border-b border-slate-100 px-4 py-3">
                <h2 className="text-xl font-semibold">Batch rows</h2>
                <p className="mt-1 text-sm text-slate-500">{batchIntro}</p>
                <form action={postCustomerReceiptCashBatchAction} className="mt-3 flex flex-wrap items-center gap-2">
                  <input type="hidden" name="batch_id" value={batchId} />
                  <button
                    type="submit"
                    disabled={!canPost}
                    className="rounded-lg bg-emerald-700 px-3 py-1.5 text-[11px] font-bold text-white disabled:bg-slate-200 disabled:text-slate-500"
                  >
                    {isOutBatch ? "Post supplier/shipper OUT batch to Sage" : "Post customer receipt batch to Sage"}
                  </button>
                  <span className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-[11px] font-bold text-slate-600">
                    {livePostingEnabled ? "Live Sage cash flag enabled" : "Live Sage cash flag disabled"}
                  </span>
                </form>
                {!livePostingEnabled ? <p className="mt-2 text-xs font-semibold text-amber-700">Set {flagName}=true before live posting this cash batch category.</p> : null}
              </div>
              <div className="overflow-x-auto">
                <table className="min-w-[1320px] divide-y divide-slate-200 text-xs">
                  <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
                    <tr><th className="px-3 py-2 text-left">Status</th><th className="px-3 py-2 text-left">Order</th><th className="px-3 py-2 text-left">Counterparty</th><th className="px-3 py-2 text-left">Short ref</th><th className="px-3 py-2 text-right">Amount</th><th className="px-3 py-2 text-left">Sage contact</th><th className="px-3 py-2 text-left">Sage bank</th><th className="px-3 py-2 text-left">Sage result</th><th className="px-3 py-2 text-left">Statement/Auth</th></tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100 bg-white">
                    {rows.map((row) => {
                      const refs = asObject(row.internal_reference_json);
                      const rowIsOut = outBatchCategories.includes(text(row.posting_category));
                      return (
                        <tr key={text(row.batch_row_id)} className="align-top">
                          <td className="px-3 py-3"><Pill value={row.row_posting_status} /><p className="mt-1 text-[11px] text-slate-500">{pretty(row.row_validation_status)}</p>{text(row.error_message) ? <p className="mt-1 text-[11px] font-semibold text-rose-700">{short(row.error_message, 70)}</p> : null}</td>
                          <td className="px-3 py-3 font-mono text-[11px] font-bold">{short(row.order_ref, 32)}</td>
                          <td className="px-3 py-3"><p className="font-bold">{short(row.counterparty_name, 34)}</p><p className="text-[11px] text-slate-500">{pretty(row.counterparty_type)}</p></td>
                          <td className="px-3 py-3 font-mono text-[11px]">{short(row.short_reference, 42)}</td>
                          <td className="px-3 py-3 text-right font-bold">{money.format(amount(row.amount_gbp))}</td>
                          <td className="px-3 py-3"><p className="font-mono text-[11px]">{short(row.sage_contact_id, 34)}</p><p className="text-[11px] text-slate-500">{short(row.sage_contact_name, 34)}</p></td>
                          <td className="px-3 py-3 font-mono text-[11px]">{short(row.sage_bank_account_id, 34)}</td>
                          <td className="px-3 py-3"><p className="font-mono text-[11px]">{short(row.sage_object_id, 34)}</p>{rowIsOut ? <p className="text-[11px] text-slate-500">Allocation {pretty(row.sage_allocation_status)} · {short(row.sage_allocation_id, 28)}</p> : <p className="text-[11px] text-slate-500">POA {short(row.sage_payment_on_account_id, 28)}</p>}<p className="text-[11px] text-slate-500">{short(row.sage_reference, 32)}</p></td>
                          <td className="px-3 py-3"><p className="font-mono text-[11px]">{short(row.statement_line_id, 34)}</p><p className="text-[11px] text-slate-500">{short(refs.auth_ref || refs.reference_raw, 34)}</p></td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>

            <section className="grid gap-3 lg:grid-cols-2">
              {rows.map((row) => <PayloadBlock key={`${text(row.batch_row_id)}-payload`} title={`Frozen Sage payload · ${text(row.short_reference)}`} value={row.request_payload} />)}
              {rows.map((row) => <PayloadBlock key={`${text(row.batch_row_id)}-response`} title={`Sage response · ${text(row.short_reference)}`} value={row.sage_response_payload} />)}
              {rows.map((row) => outBatchCategories.includes(text(row.posting_category)) ? <PayloadBlock key={`${text(row.batch_row_id)}-alloc-request`} title={`Allocation request · ${text(row.short_reference)}`} value={row.sage_allocation_request_payload} /> : null)}
              {rows.map((row) => outBatchCategories.includes(text(row.posting_category)) ? <PayloadBlock key={`${text(row.batch_row_id)}-alloc-response`} title={`Allocation response · ${text(row.short_reference)}`} value={row.sage_allocation_response_payload} /> : null)}
              {rows.map((row) => <PayloadBlock key={`${text(row.batch_row_id)}-refs`} title={`Internal reference trace · ${text(row.short_reference)}`} value={row.internal_reference_json} />)}
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
