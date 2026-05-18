import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { validateSagePostingBatchPayloadsAction } from "../../actions";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";
type SearchParams = Record<string, string | string[] | undefined>;

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

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function getPath(value: unknown, path: Array<string | number>): unknown {
  let current: unknown = value;
  for (const part of path) {
    if (typeof part === "number") {
      if (!Array.isArray(current)) return undefined;
      current = current[part];
    } else {
      if (!current || typeof current !== "object" || Array.isArray(current)) return undefined;
      current = (current as Row)[part];
    }
  }
  return current;
}

function firstText(value: unknown, paths: Array<Array<string | number>>) {
  for (const path of paths) {
    const found = text(getPath(value, path));
    if (found) return found;
  }
  return "";
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
  if (["included", "validated", "posted", "draft", "local_validated_pending_sage_dry_run", "dry_run_validated", "ok", "source_evidence_available", "present"].includes(raw)) return "complete";
  if (["excluded", "blocked", "failed_retryable", "failed_terminal", "dry_run_failed", "missing_resolved_lines", "missing_net_vat_gross_fields", "net_plus_vat_not_equal_gross", "gross_total_mismatch", "missing_source_evidence_file", "missing", "missing_sage_line_description"].includes(raw)) return "blocked";
  if (["posting", "posting_disabled_until_sage_connection_tested", "not_dry_run_validated"].includes(raw)) return "action";
  if (["cancelled", "excluded_before_validation", "not_applicable"].includes(raw)) return "review";
  return "muted";
}

function Chip({ value }: { value: unknown }) {
  return <span className={`inline-flex max-w-[190px] truncate rounded-full border px-2 py-0.5 text-[10px] font-bold leading-4 ${toneClass(statusTone(value))}`}>{pretty(value)}</span>;
}

function StatPill({ label, value, tone }: { label: string; value: string; tone: Tone }) {
  return (
    <span className={`inline-flex items-center gap-1 rounded-full border px-2 py-1 text-[11px] font-bold leading-4 ${toneClass(tone)}`}>
      <span className="opacity-70">{label}</span>
      <span>{value}</span>
    </span>
  );
}

function EvidenceLink({ url }: { url: unknown }) {
  const href = text(url);
  if (!href) return <span className="text-[11px] font-semibold text-rose-700">No source file</span>;
  return <a href={href} target="_blank" rel="noreferrer" className="text-[11px] font-bold text-sky-700 underline">Open source file</a>;
}

function lineDescription(line: Row) {
  return firstText(line, [
    ["description"],
    ["posting_description"],
    ["item_description"],
    ["source_description"],
    ["name"],
  ]);
}

function lineLedgerId(line: Row) {
  return firstText(line, [["sage_ledger_account_id"], ["resolved_ledger_account_id"]]);
}

function lineTaxId(line: Row) {
  return firstText(line, [["sage_tax_rate_id"], ["resolved_tax_rate_id"]]);
}

function lineQuantity(line: Row) {
  return text(line.quantity) || text(line.qty) || "1";
}

function lineAmount(line: Row) {
  return firstText(line, [["gross_amount_gbp"], ["total_line_amount_gbp"], ["line_total_gbp"], ["amount_gbp"], ["unit_price_gbp"], ["unit_price"]]);
}

function sageFacts(row: Row) {
  const payload = asObject(row.request_payload_json);
  const lines = asArray(payload.resolved_lines).map(asObject);
  const firstLine = lines[0] ?? {};
  const sourcePayload = asObject(payload.source_payload);

  const sourceRef = firstText(payload, [
    ["sage_header", "reference"],
    ["supplier_invoice_ref"],
    ["shipping_document_ref"],
    ["document_ref"],
    ["source_payload", "supplier_invoice_ref"],
    ["source_payload", "document_ref"],
    ["commercial_payload", "sage_header", "reference"],
  ]) || text(row.reference_text);

  const sourceDate = firstText(payload, [
    ["supplier_invoice_date"],
    ["invoice_date"],
    ["document_date"],
    ["shipping_document_date"],
    ["source_payload", "document_date"],
    ["source_payload", "supplier_invoice_date"],
    ["source_payload", "invoice_date"],
  ]);

  const sourceFile = text(row.source_invoice_file_url) || firstText(payload, [
    ["source_evidence", "file_url"],
    ["supplier_invoice_pdf_url"],
    ["invoice_pdf_url"],
    ["document_file_url"],
    ["source_payload", "supplier_invoice_pdf_url"],
    ["source_payload", "invoice_pdf_url"],
    ["source_payload", "document_file_url"],
  ]);

  const contactId = firstText(payload, [
    ["customer_target", "sage_contact_id"],
    ["supplier_target", "sage_contact_id"],
    ["shipper_target", "sage_contact_id"],
    ["source_payload", "customer_target", "sage_contact_id"],
    ["source_payload", "supplier_target", "sage_contact_id"],
    ["source_payload", "shipper_target", "sage_contact_id"],
  ]);

  const contactDisplay = firstText(payload, [
    ["customer_target", "sage_contact_display_name"],
    ["customer_target", "display_name"],
    ["supplier_target", "sage_contact_display_name"],
    ["supplier_target", "display_name"],
    ["shipper_target", "sage_contact_display_name"],
    ["counterparty_name"],
  ]) || text(row.counterparty_name);

  const ledgerId = lineLedgerId(firstLine) || firstText(payload, [["ledger_resolution", "sage_ledger_account_id"]]);

  const ledgerDisplay = firstText(firstLine, [
    ["sage_ledger_account_display"],
    ["resolver_ledger_account_role"],
    ["ledger_account_role"],
  ]) || firstText(payload, [["ledger_resolution", "sage_ledger_account_display"], ["ledger_resolution", "ledger_account_role"]]);

  const taxRateId = lineTaxId(firstLine) || firstText(payload, [["tax_resolution", "sage_tax_rate_id"]]);

  const taxDisplay = firstText(firstLine, [
    ["sage_tax_rate_display"],
    ["tax_rate_label"],
  ]) || firstText(payload, [["tax_resolution", "sage_tax_rate_display"], ["tax_resolution", "display_vat_code"]]);

  const missingLineDescriptions = lines.filter((line) => !lineDescription(line)).length;

  return {
    payload,
    sourcePayload,
    lines,
    missingLineDescriptions,
    sourceRef,
    sourceDate,
    sourceFile,
    contactId,
    contactDisplay,
    ledgerId,
    ledgerDisplay,
    taxRateId,
    taxDisplay,
  };
}

function SourceFactsCell({ row }: { row: Row }) {
  const facts = sageFacts(row);
  return (
    <div className="space-y-1 text-[11px] leading-4">
      <p className="font-bold text-slate-900">Ref: {facts.sourceRef || "—"}</p>
      <p className="text-slate-600">Date: {facts.sourceDate || "—"}</p>
      <p className="text-slate-600">Order: {text(row.order_ref) || firstText(facts.payload, [["source_order_ref"], ["order_ref"]]) || "—"}</p>
      <p className="text-slate-600">Source: {pretty(row.source_table)} · {short(row.source_id, 20)}</p>
      <EvidenceLink url={facts.sourceFile} />
    </div>
  );
}

function LineFactsBlock({ row }: { row: Row }) {
  const facts = sageFacts(row);
  if (facts.lines.length === 0) {
    return <p className="text-[11px] font-semibold text-rose-700">No resolved lines</p>;
  }

  return (
    <div className="mt-1 space-y-1 rounded-lg border border-slate-200 bg-slate-50 p-2">
      <p className="text-[10px] font-bold uppercase tracking-wide text-slate-500">Sage line facts</p>
      {facts.lines.slice(0, 3).map((line, index) => {
        const description = lineDescription(line);
        const ledger = lineLedgerId(line);
        const tax = lineTaxId(line);
        return (
          <div key={`${description || "line"}-${index}`} className="border-t border-slate-200 pt-1 first:border-t-0 first:pt-0">
            <p className={`font-bold ${description ? "text-slate-900" : "text-rose-700"}`}>Desc: {description || "missing"}</p>
            <p className="text-slate-600">Qty {lineQuantity(line)} · Amount {lineAmount(line) ? gbp(lineAmount(line)) : "—"}</p>
            <p className={`${ledger ? "text-slate-600" : "text-rose-700"}`}>Ledger {short(ledger, 28) || "missing"}</p>
            <p className={`${tax ? "text-slate-600" : "text-rose-700"}`}>Tax {short(tax, 28) || "missing"}</p>
          </div>
        );
      })}
      {facts.lines.length > 3 ? <p className="text-[10px] font-semibold text-slate-500">+ {facts.lines.length - 3} more line(s)</p> : null}
    </div>
  );
}

function SageTargetCell({ row }: { row: Row }) {
  const facts = sageFacts(row);
  return (
    <div className="space-y-1 text-[11px] leading-4">
      <p className="font-semibold text-slate-900">Contact: {facts.contactDisplay || text(row.counterparty_name) || "—"}</p>
      <p className={`font-mono ${facts.contactId ? "text-slate-700" : "text-rose-700"}`}>Contact ID: {short(facts.contactId, 28) || "missing"}</p>
      <p className={`font-mono ${facts.ledgerId ? "text-slate-700" : "text-rose-700"}`}>Ledger: {short(facts.ledgerId, 28) || "missing"}</p>
      {facts.ledgerDisplay ? <p className="text-slate-500">{short(facts.ledgerDisplay, 42)}</p> : null}
      <p className={`font-mono ${facts.taxRateId ? "text-slate-700" : "text-rose-700"}`}>Tax: {short(facts.taxRateId, 28) || "missing"}</p>
      {facts.taxDisplay ? <p className="text-slate-500">{short(facts.taxDisplay, 42)}</p> : null}
      <p className={facts.missingLineDescriptions > 0 ? "text-rose-700 font-semibold" : "text-slate-500"}>Lines: {facts.lines.length}{facts.missingLineDescriptions > 0 ? ` · ${facts.missingLineDescriptions} missing description` : ""}</p>
      <LineFactsBlock row={row} />
    </div>
  );
}

function ApControlCell({ row }: { row: Row }) {
  if (text(row.document_lane) !== "supplier_goods_ap") {
    return <span className="text-[11px] text-slate-400">—</span>;
  }

  return (
    <div className="space-y-1 text-[11px] leading-4">
      <div className="grid grid-cols-3 gap-1 font-semibold text-slate-800">
        <span>Net {gbp(row.ap_net_amount_gbp)}</span>
        <span>VAT {gbp(row.ap_vat_amount_gbp)}</span>
        <span>Gross {gbp(row.ap_gross_amount_gbp)}</span>
      </div>
      <div className="flex flex-wrap gap-1">
        <Chip value={row.ap_vat_control_status} />
        <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 font-bold text-slate-700">VAT {text(row.ap_vat_rate_summary) || "—"}%</span>
        <Chip value={row.source_evidence_status} />
      </div>
    </div>
  );
}

export default async function PostingBatchDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ batch_id: string }> | { batch_id: string };
  searchParams?: Promise<SearchParams> | SearchParams;
}) {
  const resolvedParams = await Promise.resolve(params);
  const resolvedSearchParams = await Promise.resolve(searchParams ?? {});
  const batchId = resolvedParams.batch_id;
  const successMessage = text(resolvedSearchParams.success);
  const errorMessage = text(resolvedSearchParams.error);

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
  const dryRunValidRows = rows.filter((row) => text(row.payload_validation_status) === "dry_run_validated");
  const dryRunFailedRows = rows.filter((row) => text(row.payload_validation_status) === "dry_run_failed");
  const dryRunPendingRows = includedRows.filter((row) => !["dry_run_validated", "dry_run_failed"].includes(text(row.payload_validation_status)));
  const canValidatePayloads = !error && includedRows.length > 0;
  const supplierGoodsRows = rows.filter((row) => text(row.document_lane) === "supplier_goods_ap" && text(row.posting_status) !== "excluded");
  const supplierVatBlocked = supplierGoodsRows.some((row) => !["ok", "not_applicable", ""].includes(text(row.ap_vat_control_status)) || text(row.source_evidence_status) === "missing_source_evidence_file");
  const targetMissingRows = includedRows.filter((row) => {
    const facts = sageFacts(row);
    return !facts.contactId || !facts.ledgerId || !facts.taxRateId || facts.lines.length === 0 || facts.missingLineDescriptions > 0;
  });

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1900px] space-y-3">
        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
            <div className="min-w-0">
              <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Posting batch detail</p>
                <span className="rounded-full border border-amber-200 bg-amber-50 px-2 py-1 text-[10px] font-bold text-amber-900">Posting disabled · no Sage object creation</span>
              </div>
              <h1 className="mt-1 truncate text-3xl font-semibold tracking-tight sm:text-4xl">{text(first.batch_ref) || "Posting batch"}</h1>
              <p className="mt-1 max-w-5xl text-sm leading-5 text-slate-600">Local batch lock plus Phase 11 dry-run validation. All lanes must show source facts, Sage target IDs, actual line descriptions and amount controls before adapter work.</p>
              <p className="mt-1 text-xs font-semibold text-slate-500">Batch id {batchId}</p>
              <form action={validateSagePostingBatchPayloadsAction} className="mt-3 flex flex-wrap items-center gap-2">
                <input type="hidden" name="batch_id" value={batchId} />
                <button
                  type="submit"
                  disabled={!canValidatePayloads}
                  className="rounded-2xl bg-violet-700 px-4 py-2 text-sm font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600"
                >
                  Validate Sage payloads — dry run only
                </button>
                <span className="rounded-2xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs font-bold text-amber-900">No Sage API posting endpoint is called.</span>
              </form>
            </div>
            <div className="flex shrink-0 flex-wrap gap-1.5 xl:max-w-[840px] xl:justify-end">
              <StatPill label="Status" value={pretty(first.status)} tone={statusTone(first.status)} />
              <StatPill label="Lane" value={pretty(first.lane)} tone="review" />
              <StatPill label="Included" value={String(summary.included_count ?? includedRows.length)} tone={includedRows.length > 0 ? "complete" : "muted"} />
              <StatPill label="Excluded" value={String(summary.excluded_count ?? excludedRows.length)} tone={excludedRows.length > 0 ? "blocked" : "complete"} />
              <StatPill label="Dry-run OK" value={String(dryRunValidRows.length)} tone={dryRunValidRows.length > 0 ? "complete" : "muted"} />
              <StatPill label="Dry-run failed" value={String(dryRunFailedRows.length)} tone={dryRunFailedRows.length > 0 ? "blocked" : "complete"} />
              <StatPill label="Target gaps" value={String(targetMissingRows.length)} tone={targetMissingRows.length > 0 ? "blocked" : "complete"} />
              <StatPill label="Dry-run pending" value={String(dryRunPendingRows.length)} tone={dryRunPendingRows.length > 0 ? "action" : "complete"} />
              <StatPill label="Value" value={gbp(summary.total_included_value ?? first.total_amount_gbp)} tone="complete" />
              <StatPill label="AP net" value={gbp(summary.supplier_goods_ap_net_total_gbp)} tone={supplierGoodsRows.length > 0 ? "complete" : "muted"} />
              <StatPill label="AP VAT" value={gbp(summary.supplier_goods_ap_vat_total_gbp)} tone={supplierGoodsRows.length > 0 ? "complete" : "muted"} />
              <StatPill label="AP gross" value={gbp(summary.supplier_goods_ap_gross_total_gbp)} tone={supplierGoodsRows.length > 0 ? "complete" : "muted"} />
            </div>
          </div>
          {successMessage ? <p className="mt-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{successMessage}</p> : null}
          {errorMessage ? <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{errorMessage}</p> : null}
          {supplierVatBlocked ? <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Supplier goods AP is not Sage-ready: VAT split or source evidence is missing/invalid.</p> : null}
          {targetMissingRows.length > 0 ? <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Sage target facts are incomplete on {targetMissingRows.length} row(s). Do not build/post the adapter until contact, ledger, tax and actual line descriptions are visible.</p> : null}
          {error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch detail RPC unavailable: {error.message}. Run the latest batch detail migration before testing this page.</p> : null}
          {!error && rows.length === 0 ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">No batch rows found for this batch id.</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="flex flex-col gap-2 border-b border-slate-100 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Batch rows</h2>
              <p className="mt-1 text-sm text-slate-500">Each row must show source facts, Sage target IDs, actual invoice line descriptions and amount controls. If missing, stop before Sage adapter.</p>
            </div>
          </div>
          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1880px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[96px]" />
                <col className="w-[118px]" />
                <col className="w-[136px]" />
                <col className="w-[260px]" />
                <col className="w-[300px]" />
                <col className="w-[84px]" />
                <col className="w-[150px]" />
                <col className="w-[235px]" />
                <col className="w-[285px]" />
                <col className="w-[150px]" />
                <col className="w-[240px]" />
              </colgroup>
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 text-left">Status</th>
                  <th className="px-2 py-2 text-left">Lane</th>
                  <th className="px-2 py-2 text-left">Document</th>
                  <th className="px-2 py-2 text-left">Source facts</th>
                  <th className="px-2 py-2 text-left">Sage target + lines</th>
                  <th className="px-2 py-2 text-right">Amount</th>
                  <th className="px-2 py-2 text-left">Payload validation</th>
                  <th className="px-2 py-2 text-left">AP VAT / evidence</th>
                  <th className="px-2 py-2 text-left">Counterparty</th>
                  <th className="px-2 py-2 text-left">Snapshot / idem</th>
                  <th className="px-2 py-2 text-left">Reason / error</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? <tr><td colSpan={11} className="px-3 py-8 text-center text-sm text-slate-500">No rows.</td></tr> : rows.map((row) => (
                  <tr key={text(row.row_id) || `${text(row.snapshot_id)}-${text(row.source_id)}`} className="align-top hover:bg-slate-50">
                    <td className="px-2 py-2"><Chip value={row.posting_status} /></td>
                    <td className="px-2 py-2"><p className="truncate font-bold text-slate-950">{pretty(row.document_lane)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{pretty(row.sage_object_type)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-bold text-slate-950">{pretty(row.document_type)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{pretty(row.source_table)}</p></td>
                    <td className="px-2 py-2"><SourceFactsCell row={row} /></td>
                    <td className="px-2 py-2"><SageTargetCell row={row} /></td>
                    <td className="px-2 py-2 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}<p className="text-[11px] font-normal text-slate-500">{text(row.currency_code) || "GBP"}</p></td>
                    <td className="px-2 py-2"><Chip value={row.payload_validation_status} /></td>
                    <td className="px-2 py-2"><ApControlCell row={row} /></td>
                    <td className="px-2 py-2"><p className="truncate font-semibold text-slate-900">{text(row.counterparty_name) || "—"}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{short(sageFacts(row).contactDisplay, 48)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-mono text-[11px] font-bold text-slate-950" title={text(row.snapshot_id)}>{short(row.snapshot_id, 26)}</p><p className="mt-0.5 truncate font-mono text-[11px] text-slate-500" title={text(row.idempotency_key)}>{short(row.idempotency_key, 28)}</p></td>
                    <td className="px-2 py-2"><p className="line-clamp-4 text-[11px] font-semibold leading-4 text-slate-600">{text(row.exclusion_reason) || text(row.error_message) || "—"}</p></td>
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
