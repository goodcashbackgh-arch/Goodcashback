import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type CountResult = { count: number; error: string | null };
type RowsResult = { rows: Row[]; error: string | null };

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
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
  const raw = text(value).trim();
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 32) {
  const raw = text(value).trim();
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function formatDate(value: unknown) {
  const raw = text(value).trim();
  if (!raw) return "—";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(date);
}

function toneClass(tone: "ok" | "warn" | "block" | "info" | "muted") {
  if (tone === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "warn") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "block") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "info") return "border-sky-200 bg-sky-50 text-sky-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function Card({ label, value, detail, tone = "muted" }: { label: string; value: string; detail: string; tone?: "ok" | "warn" | "block" | "info" | "muted" }) {
  return (
    <div className={`rounded-2xl border p-4 shadow-sm ${toneClass(tone)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-2 text-xs leading-5 opacity-90">{detail}</p>
    </div>
  );
}

function Stage({ step, title, detail, active = false }: { step: string; title: string; detail: string; active?: boolean }) {
  return (
    <div className={`rounded-2xl border p-4 ${active ? toneClass("info") : toneClass("muted")}`}>
      <div className="flex items-center gap-2">
        <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold ring-1 ring-slate-200">
          {step}
        </span>
        <h3 className="font-semibold">{title}</h3>
      </div>
      <p className="mt-2 text-xs leading-5 opacity-90">{detail}</p>
    </div>
  );
}

function Table({ title, rows, columns, error }: { title: string; rows: Row[]; columns: Array<{ key: string; label: string; render?: (row: Row) => string }>; error: string | null }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
          {error ? <p className="mt-1 text-xs font-semibold text-rose-700">Read error: {error}</p> : null}
        </div>
        <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">
          {rows.length} shown
        </span>
      </div>
      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
          <thead className="text-xs uppercase tracking-wide text-slate-500">
            <tr>
              {columns.map((column) => (
                <th key={column.key} className="whitespace-nowrap px-3 py-2 font-bold">{column.label}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.length === 0 ? (
              <tr>
                <td className="px-3 py-5 text-sm text-slate-500" colSpan={columns.length}>No rows to show yet.</td>
              </tr>
            ) : rows.map((row, index) => (
              <tr key={`${title}-${index}`} className="align-top">
                {columns.map((column) => (
                  <td key={column.key} className="whitespace-nowrap px-3 py-2 text-slate-700">
                    {column.render ? column.render(row) : short(row[column.key])}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

async function safeCount(supabase: Awaited<ReturnType<typeof createClient>>, table: string, configure?: (query: any) => any): Promise<CountResult> {
  let query = supabase.from(table).select("*", { count: "exact", head: true });
  if (configure) query = configure(query);
  const { count, error } = await query;
  return { count: count ?? 0, error: error?.message ?? null };
}

async function safeRows(supabase: Awaited<ReturnType<typeof createClient>>, table: string, columns: string, configure?: (query: any) => any): Promise<RowsResult> {
  let query = supabase.from(table).select(columns);
  if (configure) query = configure(query);
  const { data, error } = await query;
  return { rows: (data ?? []) as Row[], error: error?.message ?? null };
}

export default async function InternalAccountingVatPage() {
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

  if (staff.role_type !== "admin") {
    return (
      <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
        <div className="mx-auto max-w-4xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-rose-500">Admin-only VAT control</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">VAT Return Workbench</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Live VAT return controls are restricted to admin users. Supervisor users can see operational readiness elsewhere, but cannot generate, approve, post, submit evidence for, reopen, or lock VAT returns.
          </p>
        </div>
      </main>
    );
  }

  const [
    salesInvoices,
    draftSalesInvoices,
    postedSalesInvoices,
    fundingEvents,
    customerReceiptSnapshots,
    postedCustomerReceiptSnapshots,
    customerSalesSnapshots,
    postedCustomerSalesSnapshots,
    vatReturnRuns,
    vatAdjustmentJournals,
    recentSalesInvoices,
    recentFundingEvents,
    recentCashReceipts,
    recentSageSalesSnapshots,
  ] = await Promise.all([
    safeCount(supabase, "sales_invoices"),
    safeCount(supabase, "sales_invoices", (q) => q.eq("sage_status", "draft")),
    safeCount(supabase, "sales_invoices", (q) => q.eq("sage_status", "posted")),
    safeCount(supabase, "order_funding_events"),
    safeCount(supabase, "cash_posting_snapshots", (q) => q.eq("posting_category", "customer_receipt_on_account")),
    safeCount(supabase, "cash_posting_snapshots", (q) => q.eq("posting_category", "customer_receipt_on_account").in("sage_posting_status", ["posted", "posted_needs_review"])),
    safeCount(supabase, "sage_posting_snapshots", (q) => q.eq("document_lane", "customer_sales").eq("active", true)),
    safeCount(supabase, "sage_posting_snapshots", (q) => q.eq("document_lane", "customer_sales").eq("active", true).eq("sage_posting_status", "posted")),
    safeCount(supabase, "vat_return_runs"),
    safeCount(supabase, "vat_return_adjustment_journals"),
    safeRows(supabase, "sales_invoices", "id, order_id, invoice_type, amount_gbp, sage_status, consideration_received_date, sage_invoice_date, tax_point_period, sage_invoice_period, vat_box6_reported_period, zero_rating_deadline_date, zero_rating_status, sage_invoice_id, sage_posted_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(supabase, "order_funding_events", "id, order_id, event_type, amount_gbp, source_ref, source_entity_type, source_entity_id, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(supabase, "cash_posting_snapshots", "id, order_id, order_ref, amount_gbp, posting_date, posting_category, sage_posting_status, sage_object_id, sage_payment_on_account_id, created_at", (q) => q.eq("posting_category", "customer_receipt_on_account").order("created_at", { ascending: false }).limit(8)),
    safeRows(supabase, "sage_posting_snapshots", "id, document_lane, document_type, order_id, order_ref, amount_gbp, reference_text, sage_posting_status, sage_invoice_id, sage_posted_at, created_at", (q) => q.eq("document_lane", "customer_sales").eq("active", true).order("created_at", { ascending: false }).limit(8)),
  ]);

  const runTablesReady = !vatReturnRuns.error && !vatAdjustmentJournals.error;
  const openFoundationGaps = [vatReturnRuns.error, vatAdjustmentJournals.error].filter(Boolean).length;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Admin-only VAT Return Workbench</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">VAT return control dashboard</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Read-only foundation view for the new contract. This page checks the existing source facts before we add VAT return run snapshots, blockers, Sage VAT journal queues, and match/lock controls. No Sage posting buttons are exposed here.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name) || "Admin"}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <Card label="Contract gate" value="Admin only" detail="Supervisor and test override access must not control VAT returns." tone="ok" />
          <Card label="Return run layer" value={runTablesReady ? "Present" : "Missing"} detail={runTablesReady ? "VAT return run objects are visible." : "Next migration must add vat_return_runs and VAT journal queue objects."} tone={runTablesReady ? "ok" : "warn"} />
          <Card label="Sales invoices" value={String(salesInvoices.count)} detail={`${draftSalesInvoices.count} draft, ${postedSalesInvoices.count} posted. ${salesInvoices.error ?? "Existing source table readable."}`} tone={salesInvoices.error ? "block" : "info"} />
          <Card label="Funding events" value={String(fundingEvents.count)} detail={fundingEvents.error ?? "Funding events are the Box 6 prepayment source spine."} tone={fundingEvents.error ? "block" : "info"} />
          <Card label="Customer receipts" value={String(customerReceiptSnapshots.count)} detail={`${postedCustomerReceiptSnapshots.count} posted/needing review in cash snapshots.`} tone={customerReceiptSnapshots.error ? "block" : "info"} />
          <Card label="Sage sales snapshots" value={String(customerSalesSnapshots.count)} detail={`${postedCustomerSalesSnapshots.count} customer sales snapshots posted to Sage.`} tone={customerSalesSnapshots.error ? "block" : "info"} />
          <Card label="Open foundation gaps" value={String(openFoundationGaps)} detail="Counts missing return-run and VAT journal queue foundations only. Source-data blockers come next." tone={openFoundationGaps > 0 ? "warn" : "ok"} />
          <Card label="Posting controls" value="Disabled" detail="Sage VAT journal posting starts only after read-only pack and blockers are correct." tone="muted" />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold tracking-tight">Workflow preview</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                The active build stage is read-only. The next backend patch should create immutable VAT return run/source-line objects before any journal approval or Sage posting is wired.
              </p>
            </div>
            <button disabled className="rounded-xl bg-slate-200 px-4 py-2 text-sm font-semibold text-slate-500">
              Generate VAT Return Pack — not wired yet
            </button>
          </div>
          <div className="mt-5 grid gap-3 md:grid-cols-3 xl:grid-cols-6">
            <Stage step="1" title="Generate" detail="Create draft VAT pack from controlled source facts." active />
            <Stage step="2" title="Review" detail="Admin reviews Box 1/4/6/7 and source-line blockers." />
            <Stage step="3" title="Approve journals" detail="Approve only calculated Sage VAT adjustment journals." />
            <Stage step="4" title="Post journals" detail="Server-side Sage /journals only after approval." />
            <Stage step="5" title="Submit in Sage" detail="Admin submits in Sage MTD after journal posting." />
            <Stage step="6" title="Match and lock" detail="Record Sage boxes, compare and lock the return." />
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2">
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
            <h2 className="font-semibold">Confirmed current gap</h2>
            <p className="mt-2">
              The canonical VAT contract now requires VAT return run lines, journal headers, journal lines, match evidence and blockers. The repo search shows those run/journal objects are not yet implemented beyond the contract, so the first SQL patch should be additive and read-only first.
            </p>
          </div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-5 text-sm leading-6 text-sky-900">
            <h2 className="font-semibold">Source spine already visible</h2>
            <p className="mt-2">
              Existing source objects already expose customer sales invoices, funding events, customer receipt-on-account snapshots, and Sage sales posting snapshots. Those are the first facts to snapshot into VAT return lines.
            </p>
          </div>
        </section>

        <Table
          title="Recent sales invoices"
          rows={recentSalesInvoices.rows}
          error={recentSalesInvoices.error}
          columns={[
            { key: "invoice_type", label: "Type", render: (row) => pretty(row.invoice_type) },
            { key: "amount_gbp", label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { key: "sage_status", label: "Sage", render: (row) => pretty(row.sage_status) },
            { key: "consideration_received_date", label: "Payment/tax point", render: (row) => formatDate(row.consideration_received_date) },
            { key: "sage_invoice_date", label: "Invoice date", render: (row) => formatDate(row.sage_invoice_date) },
            { key: "zero_rating_deadline_date", label: "Evidence deadline", render: (row) => formatDate(row.zero_rating_deadline_date) },
            { key: "zero_rating_status", label: "Zero-rate", render: (row) => pretty(row.zero_rating_status) },
          ]}
        />

        <Table
          title="Recent funding events"
          rows={recentFundingEvents.rows}
          error={recentFundingEvents.error}
          columns={[
            { key: "event_type", label: "Event", render: (row) => pretty(row.event_type) },
            { key: "amount_gbp", label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { key: "source_entity_type", label: "Source", render: (row) => pretty(row.source_entity_type) },
            { key: "source_ref", label: "Reference", render: (row) => short(row.source_ref, 42) },
            { key: "created_at", label: "Created", render: (row) => formatDate(row.created_at) },
          ]}
        />

        <Table
          title="Recent customer receipt-on-account snapshots"
          rows={recentCashReceipts.rows}
          error={recentCashReceipts.error}
          columns={[
            { key: "order_ref", label: "Order", render: (row) => short(row.order_ref) },
            { key: "amount_gbp", label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { key: "posting_date", label: "Receipt date", render: (row) => formatDate(row.posting_date) },
            { key: "sage_posting_status", label: "Sage receipt", render: (row) => pretty(row.sage_posting_status) },
            { key: "sage_payment_on_account_id", label: "POA id", render: (row) => short(row.sage_payment_on_account_id) },
          ]}
        />

        <Table
          title="Recent Sage customer sales snapshots"
          rows={recentSageSalesSnapshots.rows}
          error={recentSageSalesSnapshots.error}
          columns={[
            { key: "document_type", label: "Document", render: (row) => pretty(row.document_type) },
            { key: "order_ref", label: "Order", render: (row) => short(row.order_ref) },
            { key: "amount_gbp", label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { key: "sage_posting_status", label: "Sage", render: (row) => pretty(row.sage_posting_status) },
            { key: "sage_invoice_id", label: "Sage invoice", render: (row) => short(row.sage_invoice_id) },
            { key: "sage_posted_at", label: "Posted", render: (row) => formatDate(row.sage_posted_at) },
          ]}
        />
      </div>
    </main>
  );
}
