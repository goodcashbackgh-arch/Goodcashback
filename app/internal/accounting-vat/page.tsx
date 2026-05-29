import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "ok" | "warn" | "block" | "info" | "muted";

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

function short(value: unknown, max = 34) {
  const raw = text(value).trim();
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function formatDate(value: unknown) {
  const raw = text(value).trim();
  if (!raw) return "—";
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(date);
}

function toneClass(tone: Tone) {
  if (tone === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "warn") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "block") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "info") return "border-sky-200 bg-sky-50 text-sky-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function Card({ label, value, detail, tone = "muted" }: { label: string; value: string; detail: string; tone?: Tone }) {
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

async function safeCount(db: any, table: string, configure?: (query: any) => any) {
  let query = db.from(table).select("*", { count: "exact", head: true });
  if (configure) query = configure(query);
  const { count, error } = await query;
  return { count: count ?? 0, error: error?.message ? String(error.message) : null };
}

async function safeRows(db: any, table: string, columns: string, configure?: (query: any) => any) {
  let query = db.from(table).select(columns);
  if (configure) query = configure(query);
  const { data, error } = await query;
  return { rows: (data ?? []) as Row[], error: error?.message ? String(error.message) : null };
}

function MiniTable({ title, rows, error, columns }: { title: string; rows: Row[]; error: string | null; columns: Array<{ label: string; render: (row: Row) => string }> }) {
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
                <th key={column.label} className="whitespace-nowrap px-3 py-2 font-bold">{column.label}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.length === 0 ? (
              <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={columns.length}>No rows to show yet.</td></tr>
            ) : rows.map((row, index) => (
              <tr key={`${title}-${index}`}>
                {columns.map((column) => (
                  <td key={column.label} className="whitespace-nowrap px-3 py-2 text-slate-700">{column.render(row)}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export default async function InternalAccountingVatPage() {
  const supabase = await createClient();
  const db = supabase as any;
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

  if (text((staff as Row).role_type) !== "admin") {
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
    receiptSnapshots,
    postedReceiptSnapshots,
    customerSalesSnapshots,
    postedCustomerSalesSnapshots,
    vatReturnRuns,
    vatReturnRunLines,
    vatAdjustmentJournals,
    vatAdjustmentJournalLines,
    vatMatchEvidence,
    vatBlockers,
    openVatBlockers,
    recentVatRuns,
    recentVatBlockers,
    recentVatJournals,
    recentSalesInvoices,
    recentFundingEvents,
    recentReceipts,
    recentSageSales,
  ] = await Promise.all([
    safeCount(db, "sales_invoices"),
    safeCount(db, "sales_invoices", (q) => q.eq("sage_status", "draft")),
    safeCount(db, "sales_invoices", (q) => q.eq("sage_status", "posted")),
    safeCount(db, "order_funding_events"),
    safeCount(db, "cash_posting_snapshots", (q) => q.eq("posting_category", "customer_receipt_on_account")),
    safeCount(db, "cash_posting_snapshots", (q) => q.eq("posting_category", "customer_receipt_on_account").in("sage_posting_status", ["posted", "posted_needs_review"])),
    safeCount(db, "sage_posting_snapshots", (q) => q.eq("document_lane", "customer_sales").eq("active", true)),
    safeCount(db, "sage_posting_snapshots", (q) => q.eq("document_lane", "customer_sales").eq("active", true).eq("sage_posting_status", "posted")),
    safeCount(db, "vat_return_runs"),
    safeCount(db, "vat_return_run_lines"),
    safeCount(db, "vat_return_adjustment_journals"),
    safeCount(db, "vat_return_adjustment_journal_lines"),
    safeCount(db, "vat_return_sage_match_evidence"),
    safeCount(db, "vat_return_blockers"),
    safeCount(db, "vat_return_blockers", (q) => q.eq("status", "open")),
    safeRows(db, "vat_return_runs", "id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp, locked_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(db, "vat_return_blockers", "id, blocker_code, severity, status, source_table, source_ref, message, required_action, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(db, "vat_return_adjustment_journals", "id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_ref, posted_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(db, "sales_invoices", "id, invoice_type, amount_gbp, sage_status, consideration_received_date, sage_invoice_date, tax_point_period, sage_invoice_period, zero_rating_deadline_date, zero_rating_status, sage_invoice_id, sage_posted_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(db, "order_funding_events", "id, event_type, amount_gbp, source_ref, source_entity_type, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    safeRows(db, "cash_posting_snapshots", "id, order_ref, amount_gbp, posting_date, sage_posting_status, sage_payment_on_account_id, created_at", (q) => q.eq("posting_category", "customer_receipt_on_account").order("created_at", { ascending: false }).limit(8)),
    safeRows(db, "sage_posting_snapshots", "id, document_type, order_ref, amount_gbp, sage_posting_status, sage_invoice_id, sage_posted_at, created_at", (q) => q.eq("document_lane", "customer_sales").eq("active", true).order("created_at", { ascending: false }).limit(8)),
  ]);

  const foundationObjects = [vatReturnRuns, vatReturnRunLines, vatAdjustmentJournals, vatAdjustmentJournalLines, vatMatchEvidence, vatBlockers];
  const foundationReady = foundationObjects.every((item) => !item.error);
  const openFoundationGaps = foundationObjects.filter((item) => item.error).length;

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
                Read-only foundation view for the VAT contract. This now checks the VAT return run tables, blockers, journal queue, match evidence and existing source facts. No Sage posting buttons are exposed here.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text((staff as Row).full_name) || "Admin"}</div>
              <div>{text((staff as Row).role_type)}</div>
            </div>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <Card label="Contract gate" value="Admin only" detail="Supervisor and test override access must not control VAT returns." tone="ok" />
          <Card label="Foundation layer" value={foundationReady ? "Present" : "Missing"} detail={foundationReady ? "Run, line, blocker, journal and match tables are visible." : "Apply the VAT foundation migration in Supabase before generating return packs."} tone={foundationReady ? "ok" : "warn"} />
          <Card label="Return runs" value={String(vatReturnRuns.count)} detail={vatReturnRuns.error ?? "VAT return run header records."} tone={vatReturnRuns.error ? "block" : "info"} />
          <Card label="Run lines" value={String(vatReturnRunLines.count)} detail={vatReturnRunLines.error ?? "Source-linked Box 1/4/6/7 snapshot rows."} tone={vatReturnRunLines.error ? "block" : "info"} />
          <Card label="Adjustment journals" value={String(vatAdjustmentJournals.count)} detail={vatAdjustmentJournals.error ?? `${vatAdjustmentJournalLines.count} journal lines in the queue layer.`} tone={vatAdjustmentJournals.error || vatAdjustmentJournalLines.error ? "block" : "info"} />
          <Card label="Match evidence" value={String(vatMatchEvidence.count)} detail={vatMatchEvidence.error ?? "Sage/HMRC submitted box evidence records."} tone={vatMatchEvidence.error ? "block" : "info"} />
          <Card label="Open blockers" value={String(openVatBlockers.count)} detail={vatBlockers.error ?? `${vatBlockers.count} blocker records total.`} tone={openVatBlockers.count > 0 ? "warn" : vatBlockers.error ? "block" : "ok"} />
          <Card label="Foundation gaps" value={String(openFoundationGaps)} detail="Missing/blocked foundation-table reads only. Source-data blockers come next." tone={openFoundationGaps > 0 ? "warn" : "ok"} />
          <Card label="Sales invoices" value={String(salesInvoices.count)} detail={`${draftSalesInvoices.count} draft, ${postedSalesInvoices.count} posted. ${salesInvoices.error ?? "Existing source table readable."}`} tone={salesInvoices.error ? "block" : "info"} />
          <Card label="Funding events" value={String(fundingEvents.count)} detail={fundingEvents.error ?? "Funding events are the Box 6 prepayment source spine."} tone={fundingEvents.error ? "block" : "info"} />
          <Card label="Customer receipts" value={String(receiptSnapshots.count)} detail={`${postedReceiptSnapshots.count} posted/needing review in cash snapshots.`} tone={receiptSnapshots.error ? "block" : "info"} />
          <Card label="Sage sales snapshots" value={String(customerSalesSnapshots.count)} detail={`${postedCustomerSalesSnapshots.count} customer sales snapshots posted to Sage.`} tone={customerSalesSnapshots.error ? "block" : "info"} />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold tracking-tight">Workflow preview</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Current stage is read-only. The next backend step is a controlled generator RPC that creates a draft return run and source-line snapshot. Journal approval and Sage posting remain disabled.
              </p>
            </div>
            <button disabled className="rounded-xl bg-slate-200 px-4 py-2 text-sm font-semibold text-slate-500">
              Generate VAT Return Pack — disabled until RPC exists
            </button>
          </div>
          <div className="mt-5 grid gap-3 md:grid-cols-3 xl:grid-cols-6">
            <Stage step="1" title="Generate" detail="Create draft VAT pack from controlled source facts." active />
            <Stage step="2" title="Review" detail="Admin reviews Box 1/4/6/7 and blockers." />
            <Stage step="3" title="Approve journals" detail="Approve only calculated Sage VAT adjustment journals." />
            <Stage step="4" title="Post journals" detail="Server-side Sage /journals only after approval." />
            <Stage step="5" title="Submit in Sage" detail="Admin submits in Sage MTD after journal posting." />
            <Stage step="6" title="Match and lock" detail="Record Sage boxes, compare and lock." />
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2">
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm leading-6 text-emerald-900">
            <h2 className="font-semibold">Foundation now wired</h2>
            <p className="mt-2">
              This dashboard reads the new VAT return run, line, blocker, adjustment journal, journal-line and match-evidence tables. If the migration has been applied, the cards will show the foundation as present.
            </p>
          </div>
          <div className="rounded-3xl border border-sky-200 bg-sky-50 p-5 text-sm leading-6 text-sky-900">
            <h2 className="font-semibold">Source spine still visible</h2>
            <p className="mt-2">
              Customer sales invoices, funding events, customer receipt-on-account snapshots, and Sage sales posting snapshots remain visible because these are the first facts to snapshot into VAT return lines.
            </p>
          </div>
        </section>

        <MiniTable
          title="Recent VAT return runs"
          rows={recentVatRuns.rows}
          error={recentVatRuns.error}
          columns={[
            { label: "Run", render: (row) => short(row.run_ref) },
            { label: "Period", render: (row) => short(row.return_period_label) },
            { label: "Start", render: (row) => formatDate(row.period_start_date) },
            { label: "End", render: (row) => formatDate(row.period_end_date) },
            { label: "Status", render: (row) => pretty(row.status) },
            { label: "Box 1", render: (row) => gbp(row.expected_box1_gbp) },
            { label: "Box 4", render: (row) => gbp(row.expected_box4_gbp) },
            { label: "Box 6", render: (row) => gbp(row.expected_box6_gbp) },
            { label: "Box 7", render: (row) => gbp(row.expected_box7_gbp) },
          ]}
        />

        <MiniTable
          title="Recent VAT blockers"
          rows={recentVatBlockers.rows}
          error={recentVatBlockers.error}
          columns={[
            { label: "Severity", render: (row) => pretty(row.severity) },
            { label: "Status", render: (row) => pretty(row.status) },
            { label: "Code", render: (row) => short(row.blocker_code, 42) },
            { label: "Source", render: (row) => short(row.source_table) },
            { label: "Message", render: (row) => short(row.message, 72) },
            { label: "Required action", render: (row) => short(row.required_action, 72) },
          ]}
        />

        <MiniTable
          title="Recent VAT adjustment journals"
          rows={recentVatJournals.rows}
          error={recentVatJournals.error}
          columns={[
            { label: "Type", render: (row) => pretty(row.adjustment_type) },
            { label: "Box", render: (row) => short(row.target_box) },
            { label: "Direction", render: (row) => pretty(row.direction) },
            { label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { label: "Status", render: (row) => pretty(row.status) },
            { label: "Sage ref", render: (row) => short(row.sage_journal_ref) },
            { label: "Posted", render: (row) => formatDate(row.posted_at) },
          ]}
        />

        <MiniTable
          title="Recent sales invoices"
          rows={recentSalesInvoices.rows}
          error={recentSalesInvoices.error}
          columns={[
            { label: "Type", render: (row) => pretty(row.invoice_type) },
            { label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { label: "Sage", render: (row) => pretty(row.sage_status) },
            { label: "Payment/tax point", render: (row) => formatDate(row.consideration_received_date) },
            { label: "Invoice date", render: (row) => formatDate(row.sage_invoice_date) },
            { label: "Evidence deadline", render: (row) => formatDate(row.zero_rating_deadline_date) },
            { label: "Zero-rate", render: (row) => pretty(row.zero_rating_status) },
          ]}
        />

        <MiniTable
          title="Recent funding events"
          rows={recentFundingEvents.rows}
          error={recentFundingEvents.error}
          columns={[
            { label: "Event", render: (row) => pretty(row.event_type) },
            { label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { label: "Source", render: (row) => pretty(row.source_entity_type) },
            { label: "Reference", render: (row) => short(row.source_ref, 42) },
            { label: "Created", render: (row) => formatDate(row.created_at) },
          ]}
        />

        <MiniTable
          title="Recent customer receipt-on-account snapshots"
          rows={recentReceipts.rows}
          error={recentReceipts.error}
          columns={[
            { label: "Order", render: (row) => short(row.order_ref) },
            { label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { label: "Receipt date", render: (row) => formatDate(row.posting_date) },
            { label: "Sage receipt", render: (row) => pretty(row.sage_posting_status) },
            { label: "POA id", render: (row) => short(row.sage_payment_on_account_id) },
          ]}
        />

        <MiniTable
          title="Recent Sage customer sales snapshots"
          rows={recentSageSales.rows}
          error={recentSageSales.error}
          columns={[
            { label: "Document", render: (row) => pretty(row.document_type) },
            { label: "Order", render: (row) => short(row.order_ref) },
            { label: "Amount", render: (row) => gbp(row.amount_gbp) },
            { label: "Sage", render: (row) => pretty(row.sage_posting_status) },
            { label: "Sage invoice", render: (row) => short(row.sage_invoice_id) },
            { label: "Posted", render: (row) => formatDate(row.sage_posted_at) },
          ]}
        />
      </div>
    </main>
  );
}
