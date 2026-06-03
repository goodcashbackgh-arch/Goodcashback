import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveDirectSagePurchasePostingLinesAction } from "./actions";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
function text(v: unknown): string { if (typeof v === "string") return v.trim(); if (typeof v === "number" && Number.isFinite(v)) return String(v); if (Array.isArray(v)) return text(v[0]); return ""; }
function num(v: unknown): number { if (typeof v === "number" && Number.isFinite(v)) return v; const n = Number(text(v).replace(/,/g, "")); return Number.isFinite(n) ? n : 0; }
function obj(v: unknown): Row { return v && typeof v === "object" && !Array.isArray(v) ? v as Row : {}; }
function yes(v: unknown): boolean { return v === true || text(v).toLowerCase() === "true"; }
function gbp(v: unknown): string { return money.format(num(v)); }
function label(v: unknown): string { const s = text(v).replaceAll("[object Object]", "").trim(); return s || "VAT return"; }
function confirmationTitle(row: Row): string { const title = text(row.return_period_label).replaceAll("[object Object]", "").replace(/\s*\(\s*\)\s*$/, "").trim(); return title || label(row.run_ref); }
function cut(v: unknown, max = 52): string { const s = label(v); return s.length > max ? `${s.slice(0, max - 1)}…` : s; }
function date(v: unknown): string { const raw = text(v); if (!raw) return "—"; const parsed = new Date(raw); return Number.isNaN(parsed.getTime()) ? raw : new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed); }
function review(s: Row): Row { return obj(obj(s.source_summary).purchase_vat_line_review); }
function totalsOnlySageDraftImport(row: Row): boolean { const sourceSummary = obj(row.source_summary); return text(row.source_basis).startsWith("sage_draft_vat_return_totals_import") || Boolean(text(sourceSummary.source_mode)) || text(sourceSummary.version).startsWith("sage_draft_vat_return_totals_import"); }
function directRows(r: Row): Row[] { return Array.isArray(r.direct_sage_purchase_postings_not_on_platform) ? r.direct_sage_purchase_postings_not_on_platform as Row[] : []; }
function ok(n: number): boolean { return Math.abs(n) <= 0.01; }
function parseIndexes(value: unknown): number[] { return text(value).split(",").map((part) => Number(part.trim())).filter((value) => Number.isInteger(value) && value >= 0); }
function lineReviewRequired(row: Row): boolean { return yes(row.review_required) || text(row.classification) === "review_required_purchase_posting" || text(row.reason).toLowerCase().includes("review required"); }
function lineSelectable(row: Row): boolean { return text(row.classification) === "direct_sage_purchase_posting_not_on_platform" && !yes(row.platform_controlled) && !lineReviewRequired(row); }
function groupKey(row: Row): string { const primary = [row.source_type, row.sage_document_id, row.sage_api_path, row.document_label].map(text); if (primary.slice(1).some(Boolean)) return `primary:${primary.join("|")}`; return `fallback:${[row.source_type, row.document_label, row.supplier_contact, row.document_date].map(text).join("|")}`; }
function lineTaxProfile(row: Row): string { const raw = `${text(row.tax_rate)} ${text(row.tax_rate_name)} ${text(row.tax_code)}`.toLowerCase(); const net = Math.abs(num(row.net_amount)); const vat = Math.abs(num(row.vat_amount)); if (lineReviewRequired(row)) return "Review required"; if (raw.includes("20") || (net > 0 && Math.abs((vat / net) - 0.2) <= 0.01)) return "Standard 20%"; if (vat <= 0.005 || raw.includes("zero") || raw.includes("exempt") || raw.includes("outside") || raw.includes("out of scope")) return "Zero/exempt/out-of-scope"; return label(row.tax_rate); }
function selectedDocumentGroups(selectedRows: Array<{ index: number; row: Row }>): Row[] { const groups = new Map<string, Array<{ index: number; row: Row }>>(); for (const item of selectedRows) { const key = groupKey(item.row); groups.set(key, [...(groups.get(key) ?? []), item]); } return [...groups.entries()].map(([key, items]) => ({ group_key: key, selected_line_indexes: items.map((item) => item.index), document_label: text(items[0]?.row.document_label) || text(items[0]?.row.sage_document_id) || "Sage document", supplier_contact: label(items[0]?.row.supplier_contact), document_date: text(items[0]?.row.document_date), document_status: label(items[0]?.row.document_status), net_amount: items.reduce((sum, item) => sum + num(item.row.net_amount), 0), vat_amount: items.reduce((sum, item) => sum + num(item.row.vat_amount), 0), gross_amount: items.reduce((sum, item) => sum + num(item.row.gross_amount), 0), effective_box4_amount: items.reduce((sum, item) => sum + num(item.row.effective_box4_amount), 0), effective_box7_amount: items.reduce((sum, item) => sum + num(item.row.effective_box7_amount), 0), line_count: items.length, tax_profile_summary: [...new Set(items.map((item) => lineTaxProfile(item.row)))].length === 1 ? lineTaxProfile(items[0].row) : "Mixed" })); }


export default async function SageOnlyPurchaseApprovalPage({ params, searchParams }: any) {
  const runId = text((params ? await params : {})?.return_run_id);
  const query = searchParams ? await searchParams : {};
  if (!runId) redirect("/internal/accounting-vat");

  const selectedIndexes = parseIndexes(query?.selected_line_indexes);
  const requestedSnapshotId = text(query?.sage_snapshot_id);
  if (!requestedSnapshotId || selectedIndexes.length === 0) redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases&vatError=${encodeURIComponent("Select direct Sage posting lines before final approval.")}`);

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff } = await supabase.from("staff").select("role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (text((staff as Row)?.role_type) !== "admin") redirect("/internal/accounting-vat");

  const [{ data: run }, { data: snapshots }] = await Promise.all([
    (supabase as any).from("vat_return_runs").select("id, run_ref, return_period_label, expected_box4_gbp, expected_box7_gbp").eq("id", runId).maybeSingle(),
    (supabase as any).from("vat_return_sage_reconstruction_snapshots").select("id, created_at, source_basis, box4_gbp, box7_gbp, source_summary").eq("vat_return_run_id", runId).order("created_at", { ascending: false }).limit(20),
  ]);
  if (!run) redirect("/internal/accounting-vat");

  const snapshotRows = (snapshots ?? []) as Row[];
  const latestDirectSnapshot = snapshotRows.find((snapshot) => text(review(snapshot).version) === "direct_sage_purchase_postings_review_v1" && !totalsOnlySageDraftImport(snapshot));
  if (!latestDirectSnapshot || text(latestDirectSnapshot.id) !== requestedSnapshotId) redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases&vatError=${encodeURIComponent("Selected direct Sage posting snapshot is no longer current. Review the latest Box 4 / Box 7 workbench.")}`);

  const reviewRows = directRows(review(latestDirectSnapshot));
  const uniqueIndexes = [...new Set(selectedIndexes)];
  const indexesValid = selectedIndexes.length === uniqueIndexes.length && uniqueIndexes.every((index) => index >= 0 && index < reviewRows.length);
  const selectedRows = indexesValid ? uniqueIndexes.map((index) => ({ index, row: reviewRows[index] })) : [];
  const selectionValid = indexesValid && selectedRows.length > 0 && selectedRows.every(({ row }) => lineSelectable(row) && text(row.sage_document_id) && text(row.document_label));
  if (!selectionValid) redirect(`/internal/accounting-vat/returns/${runId}?tab=purchases&vatError=${encodeURIComponent("Selected direct Sage posting lines are no longer valid approval candidates.")}`);

  const documentGroups = selectedDocumentGroups(selectedRows);
  const selectedBox4 = selectedRows.reduce((sum, item) => sum + num(item.row.effective_box4_amount), 0);
  const selectedBox7 = selectedRows.reduce((sum, item) => sum + num(item.row.effective_box7_amount), 0);
  const before4 = num((run as Row).expected_box4_gbp);
  const before7 = num((run as Row).expected_box7_gbp);
  const after4 = before4 + selectedBox4;
  const after7 = before7 + selectedBox7;
  const sage4 = num(latestDirectSnapshot.box4_gbp);
  const sage7 = num(latestDirectSnapshot.box7_gbp);
  const rem4 = after4 - sage4;
  const rem7 = after7 - sage7;
  const canApprove = ok(rem4) && ok(rem7);
  const err = text(query?.vatError);

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto flex max-w-6xl flex-col gap-6">
    <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"><Link href={`/internal/accounting-vat/returns/${runId}?tab=purchases`} className="text-sm font-semibold text-sky-600">← Back to Box 4 / Box 7 purchases</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Final direct Sage posting confirmation</p><h1 className="mt-3 text-3xl font-semibold tracking-tight">{confirmationTitle(run as Row)}</h1><p className="mt-2 text-sm leading-6 text-slate-600">Confirmation-only approval for selected direct Sage postings not on platform. This creates source-linked platform VAT lines only; it does not create or post Sage adjustment journals.</p>{err ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{err}</p> : null}</section>
    <section className="grid gap-4 md:grid-cols-5"><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">Current Platform Box 4 / Box 7</p><p className="mt-2 text-xl font-extrabold">{gbp(before4)} / {gbp(before7)}</p></div><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">Selected direct Sage Box 4 / Box 7</p><p className="mt-2 text-xl font-extrabold">{gbp(selectedBox4)} / {gbp(selectedBox7)}</p></div><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">After Platform Box 4 / Box 7</p><p className="mt-2 text-xl font-extrabold">{gbp(after4)} / {gbp(after7)}</p></div><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">Sage natural Box 4 / Box 7</p><p className="mt-2 text-xl font-extrabold">{gbp(sage4)} / {gbp(sage7)}</p></div><div className={`rounded-2xl border p-4 ${canApprove ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><p className="text-xs font-bold uppercase opacity-70">Remaining difference</p><p className="mt-2 text-xl font-extrabold">{gbp(rem4)} / {gbp(rem7)}</p></div></section>
    <section className={`rounded-3xl border p-5 text-sm ${canApprove ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><h2 className="text-lg font-semibold">Nil-balance gate</h2><p className="mt-2 font-semibold">{canApprove ? "Ready. Remaining Box 4 and Box 7 differences are nil within £0.01." : "Blocked. Remaining Box 4 and Box 7 differences must both be nil within £0.01."}</p></section>
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold">Selected direct Sage postings not on platform</h2><p className="mt-1 text-sm text-slate-600">Selected documents are grouped for confirmation. Hidden form fields below still submit every underlying selected line index to the line-level approval RPC.</p><div className="mt-4 overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-left text-sm"><thead className="text-xs uppercase text-slate-500"><tr><th className="px-3 py-2">Document/ref</th><th className="px-3 py-2">Supplier/contact</th><th className="px-3 py-2">Document date</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Net</th><th className="px-3 py-2">VAT</th><th className="px-3 py-2">Gross</th><th className="px-3 py-2">Box 4 effect</th><th className="px-3 py-2">Box 7 effect</th><th className="px-3 py-2">Line count</th><th className="px-3 py-2">Tax profile</th><th className="px-3 py-2">Action/help text</th></tr></thead><tbody className="divide-y divide-slate-100">{documentGroups.map((row) => <tr key={text(row.group_key)}><td className="px-3 py-2 font-semibold">{cut(row.document_label || row.sage_document_id, 36)}</td><td className="px-3 py-2">{cut(row.supplier_contact, 34)}</td><td className="px-3 py-2">{date(row.document_date)}</td><td className="px-3 py-2">{cut(row.document_status, 24)}</td><td className="px-3 py-2 font-semibold">{gbp(row.net_amount)}</td><td className="px-3 py-2 font-semibold">{gbp(row.vat_amount)}</td><td className="px-3 py-2 font-semibold">{gbp(row.gross_amount)}</td><td className="px-3 py-2 font-semibold">{gbp(row.effective_box4_amount)}</td><td className="px-3 py-2 font-semibold">{gbp(row.effective_box7_amount)}</td><td className="px-3 py-2 font-semibold">{num(row.line_count)}</td><td className="px-3 py-2">{cut(row.tax_profile_summary, 28)}</td><td className="px-3 py-2">Copy ref / open Sage manually</td></tr>)}</tbody></table></div></section>
    <form action={approveDirectSagePurchasePostingLinesAction} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><input type="hidden" name="vat_return_run_id" value={runId} /><input type="hidden" name="sage_snapshot_id" value={requestedSnapshotId} />{uniqueIndexes.map((index) => <input key={index} type="hidden" name="selected_line_indexes" value={String(index)} />)}<div className="flex flex-wrap items-center justify-between gap-3"><div><h2 className="text-lg font-semibold">Confirm approval into platform VAT return</h2><p className="mt-1 text-sm text-slate-600">Approval inserts source-linked Box 4 / Box 7 lines with natural Sage coverage and no Sage journal requirement.</p></div><button disabled={!canApprove} className={`rounded-xl px-4 py-2 text-sm font-bold ${canApprove ? "bg-slate-950 text-white hover:bg-slate-800" : "cursor-not-allowed bg-slate-200 text-slate-500"}`}>Confirm approval into platform VAT return</button></div></form>
  </div></main>;
}
