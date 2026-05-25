import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "@/lib/supabase/admin";

type Row = Record<string, any>;
const BUCKET = "invoice-evidence";

function obj(v: unknown): Row { return v && typeof v === "object" && !Array.isArray(v) ? v as Row : {}; }
function txt(v: unknown) { return typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : typeof v === "boolean" ? (v ? "true" : "false") : ""; }
function num(v: unknown) { if (typeof v === "number" && Number.isFinite(v)) return v; if (typeof v === "string" && v.trim()) { const n = Number(v); return Number.isFinite(n) ? n : 0; } return 0; }
function get(v: unknown, path: Array<string | number>): unknown { let cur = v; for (const p of path) { if (typeof p === "number") { if (!Array.isArray(cur)) return undefined; cur = cur[p]; } else { if (!cur || typeof cur !== "object" || Array.isArray(cur)) return undefined; cur = (cur as Row)[p]; } } return cur; }
function first(v: unknown, paths: Array<Array<string | number>>) { for (const p of paths) { const x = txt(get(v, p)); if (x) return x; } return ""; }

function sourceUrl(payload: Row) {
  return first(payload, [
    ["source_evidence", "file_url"], ["evidence", "credit_note_file_url"], ["evidence", "refund_proof_file_url"], ["evidence", "internal_no_cn_memo_file_url"], ["evidence", "file_url"],
    ["credit_note_file_url"], ["refund_proof_file_url"], ["internal_no_cn_memo_file_url"],
    ["source_payload", "evidence", "credit_note_file_url"], ["source_payload", "evidence", "refund_proof_file_url"], ["source_payload", "evidence", "internal_no_cn_memo_file_url"], ["source_payload", "evidence", "file_url"],
    ["source_payload", "credit_note_file_url"], ["source_payload", "refund_proof_file_url"], ["source_payload", "internal_no_cn_memo_file_url"],
  ]);
}

function clean(s: string) { return s.replace(/£/g, "GBP ").replace(/[–—]/g, "-").replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/[^\x20-\x7E]/g, " ").replace(/\s+/g, " ").trim(); }
function esc(s: string) { return clean(s).replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)"); }
function wrap(s: string, width = 88) { const words = clean(s).split(" ").filter(Boolean); const out: string[] = []; let cur = ""; for (const w of words) { if (!cur) cur = w; else if ((cur + " " + w).length <= width) cur += " " + w; else { out.push(cur); cur = w; } } if (cur) out.push(cur); return out.length ? out : [""]; }
function pdf(lines: string[]) {
  const wrapped = lines.flatMap((l) => wrap(l)).slice(0, 48);
  const stream = ["BT", "/F1 10 Tf", "50 790 Td", ...wrapped.flatMap((l, i) => [i ? "0 -15 Td" : "", `(${esc(l)}) Tj`]).filter(Boolean), "ET"].join("\n");
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
    `4 0 obj\n<< /Length ${Buffer.byteLength(stream, "utf8")} >>\nstream\n${stream}\nendstream\nendobj\n`,
    "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
  ];
  let body = "%PDF-1.4\n"; const offsets = [0];
  for (const o of objects) { offsets.push(Buffer.byteLength(body, "utf8")); body += o; }
  const xref = Buffer.byteLength(body, "utf8"); body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets.slice(1)) body += `${String(o).padStart(10, "0")} 00000 n \n`;
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(body, "utf8");
}

function fileName(row: Row, submission: Row) { const ref = txt(row.reference_text) || txt(row.order_ref) || txt(submission.id) || "no_cn_refund_adjustment"; return `${ref.replace(/[^a-zA-Z0-9._-]+/g, "_")}_NO_CN_MEMO.pdf`; }
function canMemo(s: Row) { return txt(s.document_mode) === "refund_proof_no_credit_note" && txt(s.supplier_approval_status) === "approved_current" && txt(s.supplier_control_status) === "approved_current" && txt(s.amount_balance_status) === "balanced"; }
function patch(payload: Row, url: string, generatedAt: string) { return { ...payload, source_evidence: { ...obj(payload.source_evidence), file_url: url, evidence_type: "internal_no_cn_supplier_credit_adjustment_memo", generated_at: generatedAt }, evidence: { ...obj(payload.evidence), internal_no_cn_memo_file_url: url }, source_payload: { ...obj(payload.source_payload), document_mode: txt(obj(payload.source_payload).document_mode) || "refund_proof_no_credit_note", evidence: { ...obj(obj(payload.source_payload).evidence), internal_no_cn_memo_file_url: url } } }; }
function memoLines(row: Row, s: Row, lines: Row[]) { const amount = num(s.captured_refund_amount_abs_gbp || row.amount_gbp).toFixed(2); return [
  "INTERNAL SUPPLIER CREDIT ADJUSTMENT MEMO",
  "Reason: retailer refund received, no formal retailer credit note provided.",
  `Generated at: ${new Date().toISOString()}`,
  `Order ref: ${txt(row.order_ref) || "not recorded"}`,
  `Batch row id: ${txt(row.id) || "not recorded"}`,
  `Refund evidence submission id: ${txt(s.id)}`,
  `Original supplier invoice id: ${txt(s.original_supplier_invoice_id) || "not recorded"}`,
  `Accepted refund/credit amount: GBP ${amount}`,
  `Supplier approval status: ${txt(s.supplier_approval_status)}`,
  `Supplier control status: ${txt(s.supplier_control_status)}`,
  `Amount balance status: ${txt(s.amount_balance_status)}`,
  `Operator/staff note: ${txt(s.notes) || "No additional note recorded."}`,
  "",
  "Approved supplier credit adjustment lines:",
  ...(lines.length ? lines.map((l) => `Line ${txt(l.line_order) || "-"}: ${txt(l.description) || "Refund adjustment line"} | Qty ${txt(l.qty) || "1"} | Gross GBP ${num(l.amount_gbp).toFixed(2)}`) : ["No structured lines were returned for this memo."]),
  "",
  "Control note: this memo is generated by Goodcashback as evidence for a Sage purchase credit note equivalent. It does not assert that the retailer issued a formal credit note.",
]; }

async function uploadMemo(submissionId: string, name: string, lines: string[]) {
  const body = pdf(lines);
  const path = `generated-no-cn-memos/${submissionId}/${Date.now()}-${randomUUID()}-${name}`;
  const { error } = await supabaseAdmin.storage.from(BUCKET).upload(path, body, { contentType: "application/pdf", upsert: false });
  if (error) throw new Error(error.message);
  const { data } = supabaseAdmin.storage.from(BUCKET).getPublicUrl(path);
  return data.publicUrl || path;
}

export async function ensureNoCnSupplierCreditAdjustmentMemosForBatch(batchId: string) {
  const { data: rowsRaw, error } = await supabaseAdmin.from("sage_posting_batch_rows")
    .select("id, batch_id, snapshot_id, source_table, source_id, order_ref, reference_text, amount_gbp, request_payload_json")
    .eq("batch_id", batchId).eq("document_lane", "supplier_credit_note").is("sage_object_id", null)
    .in("posting_status", ["included", "validated", "failed_retryable", "failed_terminal"]);
  if (error) throw new Error(error.message);
  let generated = 0; let skipped = 0;
  for (const rowRaw of rowsRaw ?? []) {
    const row = rowRaw as Row; const payload = obj(row.request_payload_json);
    if (sourceUrl(payload)) { skipped += 1; continue; }
    const sourceTable = txt(row.source_table) || first(payload, [["source_table"], ["source_payload", "source_table"]]);
    const sourceId = txt(row.source_id) || first(payload, [["source_id"], ["refund_evidence_submission_id"], ["source_payload", "source_id"], ["source_payload", "refund_evidence_submission_id"]]);
    if (sourceTable !== "dispute_refund_evidence_submissions" || !sourceId) { skipped += 1; continue; }
    const { data: submissionRaw, error: submissionError } = await supabaseAdmin.from("dispute_refund_evidence_submissions")
      .select("id, document_mode, original_supplier_invoice_id, refund_proof_file_url, credit_note_file_url, notes, supplier_approval_status, supplier_control_status, amount_balance_status, captured_refund_amount_abs_gbp")
      .eq("id", sourceId).maybeSingle();
    if (submissionError) throw new Error(submissionError.message);
    const s = obj(submissionRaw);
    const existing = txt(s.credit_note_file_url) || txt(s.refund_proof_file_url);
    if (existing) {
      const patched = patch(payload, existing, new Date().toISOString());
      await supabaseAdmin.from("sage_posting_batch_rows").update({ request_payload_json: patched }).eq("id", txt(row.id));
      if (txt(row.snapshot_id)) await supabaseAdmin.from("sage_posting_snapshots").update({ resolved_payload: patched, sage_attachment_source_url: existing }).eq("id", txt(row.snapshot_id));
      skipped += 1; continue;
    }
    if (!canMemo(s)) { skipped += 1; continue; }
    const { data: lineRows, error: lineError } = await supabaseAdmin.from("dispute_refund_document_lines")
      .select("line_order, description, qty, amount_gbp").eq("refund_evidence_submission_id", sourceId).order("line_order", { ascending: true });
    if (lineError) throw new Error(lineError.message);
    const name = fileName(row, s);
    const url = await uploadMemo(sourceId, name, memoLines(row, s, (lineRows ?? []) as Row[]));
    const patched = patch(payload, url, new Date().toISOString());
    await supabaseAdmin.from("sage_posting_batch_rows").update({ request_payload_json: patched }).eq("id", txt(row.id));
    if (txt(row.snapshot_id)) await supabaseAdmin.from("sage_posting_snapshots").update({ resolved_payload: patched, sage_attachment_source_url: url, sage_attachment_file_name: name }).eq("id", txt(row.snapshot_id));
    generated += 1;
  }
  return { generated, skipped, total: (rowsRaw ?? []).length };
}
