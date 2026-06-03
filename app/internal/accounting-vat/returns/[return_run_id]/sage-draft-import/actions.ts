"use server";

import { createHash } from "node:crypto";
import { inflateRawSync } from "node:zlib";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type BoxNo = 1|2|3|4|5|6|7|8|9;
type BoxTotals = Partial<Record<BoxNo, number>>;
type Row = Record<string, unknown>;
type ZipEntry = { name: string; data: Buffer };

const ALL: BoxNo[] = [1,2,3,4,5,6,7,8,9];
const REQUIRED: BoxNo[] = [1,4,6,7];
const OPTIONAL_ZERO: BoxNo[] = [2,8,9];
const MAX_UPLOAD_BYTES = 2_000_000;

const s = (v: unknown) => typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : "";
const money2 = (v: number) => Number(v.toFixed(2));
const norm = (v: string) => v.toLowerCase().replace(/[^a-z0-9%]+/g, " ").replace(/\s+/g, " ").trim();

function parseMoney(v: unknown): number | null {
  const raw = s(v);
  if (!raw) return null;
  const brackets = /^\s*\(.*\)\s*$/.test(raw);
  const cleaned = raw.replace(/,/g, "").replace(/[£$€\s()]/g, "").replace(/[^0-9.\-]/g, "");
  if (!cleaned || cleaned === "-" || cleaned === ".") return null;
  const n = Number(cleaned);
  return Number.isFinite(n) ? money2(brackets ? -Math.abs(n) : n) : null;
}

function csvRows(input: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], cell = "", quoted = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i], next = input[i + 1];
    if (ch === '"') { if (quoted && next === '"') { cell += '"'; i++; } else quoted = !quoted; continue; }
    if (!quoted && (ch === "," || ch === "\t")) { row.push(cell.trim()); cell = ""; continue; }
    if (!quoted && (ch === "\n" || ch === "\r")) { if (ch === "\r" && next === "\n") i++; row.push(cell.trim()); if (row.some(Boolean)) rows.push(row); row = []; cell = ""; continue; }
    cell += ch;
  }
  row.push(cell.trim());
  if (row.some(Boolean)) rows.push(row);
  return rows;
}

function xmlDecode(v: string) {
  return v.replace(/&amp;/g,"&").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&#(\d+);/g,(_,c)=>String.fromCharCode(Number(c))).replace(/&#x([0-9a-f]+);/gi,(_,c)=>String.fromCharCode(parseInt(c,16)));
}

function unzip(buffer: Buffer): ZipEntry[] {
  let eocd = -1;
  for (let i = buffer.length - 22, min = Math.max(0, buffer.length - 65557); i >= min; i--) if (buffer.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error("Could not read XLSX file. Please upload a valid .xlsx file or enter the boxes manually.");
  const count = buffer.readUInt16LE(eocd + 10), central = buffer.readUInt32LE(eocd + 16);
  const out: ZipEntry[] = [];
  let p = central;
  for (let i = 0; i < count; i++) {
    if (buffer.readUInt32LE(p) !== 0x02014b50) break;
    const method = buffer.readUInt16LE(p + 10), size = buffer.readUInt32LE(p + 20), nameLen = buffer.readUInt16LE(p + 28), extraLen = buffer.readUInt16LE(p + 30), commentLen = buffer.readUInt16LE(p + 32), local = buffer.readUInt32LE(p + 42);
    const name = buffer.subarray(p + 46, p + 46 + nameLen).toString("utf8");
    const localNameLen = buffer.readUInt16LE(local + 26), localExtraLen = buffer.readUInt16LE(local + 28), start = local + 30 + localNameLen + localExtraLen;
    const raw = buffer.subarray(start, start + size);
    if (method === 0) out.push({ name, data: raw });
    if (method === 8) out.push({ name, data: inflateRawSync(raw) });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

function sharedStrings(xml: string) {
  return Array.from(xml.matchAll(/<si[\s\S]*?<\/si>/g)).map(si => Array.from(si[0].matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)).map(m => xmlDecode(m[1])).join(""));
}

function colIndex(ref: string) {
  let n = 0;
  for (const ch of ref.replace(/[^A-Z]/g, "")) n = n * 26 + ch.charCodeAt(0) - 64;
  return Math.max(0, n - 1);
}

function cellValue(attrs: string, body: string | undefined, strings: string[]) {
  const safeBody = body ?? "";
  const type = attrs.match(/\bt="([^"]+)"/)?.[1] ?? "";
  if (type === "s") return s(strings[Number(safeBody.match(/<v>([\s\S]*?)<\/v>/)?.[1] ?? "")]);
  if (type === "inlineStr") return Array.from(safeBody.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)).map(m => xmlDecode(m[1])).join("");
  return xmlDecode(safeBody.match(/<v>([\s\S]*?)<\/v>/)?.[1] ?? "");
}

function sheetText(xml: string, strings: string[]) {
  const lines: string[] = [];
  for (const r of xml.matchAll(/<row\b[\s\S]*?<\/row>/g)) {
    const cells: string[] = [];
    for (const c of r[0].matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const ref = c[1].match(/\br="([A-Z]+\d+)"/)?.[1] ?? "";
      cells[ref ? colIndex(ref) : cells.length] = cellValue(c[1], c[2], strings);
    }
    if (cells.some(x => s(x))) lines.push(cells.map(x => x ?? "").join("\t"));
  }
  return lines.join("\n");
}

function xlsxText(buffer: Buffer) {
  const files = unzip(buffer), byName = new Map(files.map(f => [f.name, f.data]));
  const strings = byName.has("xl/sharedStrings.xml") ? sharedStrings(byName.get("xl/sharedStrings.xml")!.toString("utf8")) : [];
  const text = files.filter(f => /^xl\/worksheets\/sheet\d+\.xml$/i.test(f.name)).sort((a,b)=>a.name.localeCompare(b.name)).map(f => sheetText(f.data.toString("utf8"), strings)).filter(Boolean).join("\n");
  if (!text) throw new Error("Could not find readable worksheets in the XLSX file. Enter the Sage boxes manually or export CSV from Sage.");
  return text;
}

function isXlsx(file: File) { return file.name.toLowerCase().endsWith(".xlsx") || file.type === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"; }

function strictAmount(row: string[], labelIndex: number): number | null {
  const tail = s(row[labelIndex]).replace(/.*?total\s+for\s+box\s+[1-9]\b/i, "").trim();
  if (tail) { const parsed = parseMoney(tail); if (parsed !== null) return parsed; }
  for (let i = labelIndex + 1; i < row.length; i++) { const parsed = parseMoney(row[i]); if (parsed !== null) return parsed; }
  return null;
}

function extractBoxTotalsFromText(input: string): BoxTotals {
  const totals: BoxTotals = {};
  for (const row of csvRows(input)) {
    const labelIndex = row.findIndex(cell => /\btotal\s+for\s+box\s+[1-9]\b/.test(norm(cell)));
    if (labelIndex < 0) continue;
    const box = Number(norm(row[labelIndex]).match(/\btotal\s+for\s+box\s+([1-9])\b/)?.[1] ?? "") as BoxNo;
    if (!ALL.includes(box)) continue;
    const amount = strictAmount(row, labelIndex);
    if (amount !== null) totals[box] = amount;
  }
  return totals;
}

function manualOverrides(formData: FormData): BoxTotals {
  const out: BoxTotals = {};
  for (const box of ALL) {
    const raw = s(formData.get(`box${box}_gbp`));
    if (!raw) continue;
    const parsed = parseMoney(raw);
    if (parsed === null) throw new Error(`Box ${box} manual amount is not a valid GBP value.`);
    out[box] = parsed;
  }
  return out;
}

function withDerived(input: BoxTotals): BoxTotals {
  const b: BoxTotals = { ...input };
  for (const box of OPTIONAL_ZERO) if (b[box] === undefined || b[box] === null) b[box] = 0;
  if (b[3] === undefined && b[1] !== undefined && b[2] !== undefined) b[3] = money2((b[1] ?? 0) + (b[2] ?? 0));
  if (b[5] === undefined && b[3] !== undefined && b[4] !== undefined) b[5] = money2((b[3] ?? 0) - (b[4] ?? 0));
  return b;
}

function missingRequired(boxes: BoxTotals): BoxNo[] { return REQUIRED.filter(box => boxes[box] === undefined || boxes[box] === null); }

function finalBoxes(extracted: BoxTotals, overrides: BoxTotals) {
  const boxes = withDerived({ ...extracted, ...overrides });
  const missing = missingRequired(boxes);
  if (missing.length) throw new Error(`Missing Box ${missing.join(", ")}. Upload a Sage draft export with exact Total for Box rows or enter them manually.`);
  const warnings: string[] = [];
  const calc3 = money2((boxes[1] ?? 0) + (boxes[2] ?? 0));
  const calc5 = money2(calc3 - (boxes[4] ?? 0));
  if (boxes[3] !== undefined && Math.abs((boxes[3] ?? 0) - calc3) > 0.01) warnings.push(`Extracted Box 3 ${boxes[3]} does not equal Box 1 + Box 2 ${calc3}. Sage value was preserved.`);
  if (boxes[5] !== undefined && Math.abs((boxes[5] ?? 0) - calc5) > 0.01) warnings.push(`Extracted Box 5 ${boxes[5]} does not equal Box 3 - Box 4 ${calc5}. Sage value was preserved.`);
  return { boxes: boxes as Record<BoxNo, number>, warnings };
}

async function readUpload(value: FormDataEntryValue | null) {
  if (!(value instanceof File) || value.size <= 0) return { uploadedText: "", uploadedFileSummary: null as Row | null };
  if (value.size > MAX_UPLOAD_BYTES) throw new Error("Sage draft file is too large. Export a simple VAT return XLSX/CSV/text file under 2MB.");
  const buffer = Buffer.from(await value.arrayBuffer());
  const xlsx = isXlsx(value);
  return {
    uploadedText: xlsx ? xlsxText(buffer) : buffer.toString("utf8"),
    uploadedFileSummary: { name: value.name, type: value.type || "unknown", size_bytes: value.size, sha256: createHash("sha256").update(buffer).digest("hex"), parser: xlsx ? "xlsx_strict_total_for_box_v3" : "text_strict_total_for_box_v3" },
  };
}


function uploadPurpose(formData: FormData): "draft_reconciliation" | "final_submission_evidence" {
  return s(formData.get("upload_purpose")) === "final_submission_evidence" ? "final_submission_evidence" : "draft_reconciliation";
}

function finalSubmissionTimestamp(value: unknown): string {
  const raw = s(value);
  if (!raw) return new Date().toISOString();
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) throw new Error("Sage submission timestamp is not a valid date/time.");
  return parsed.toISOString();
}

function rpcMatched(data: unknown): boolean {
  if (typeof data === "boolean") return data;
  if (data && typeof data === "object" && "matched" in data) return Boolean((data as Row).matched);
  return false;
}

async function requireAdminStaff() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Login required.");
  const { data: staff, error } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (error) throw new Error(error.message);
  if (!staff || s((staff as Row).role_type) !== "admin") throw new Error("Admin-only VAT import access required.");
  return { supabase, staff: staff as { id: string; role_type: string } };
}

export async function previewSageDraftVatReturnTotalsAction(formData: FormData) {
  const runId = s(formData.get("vat_return_run_id"));
  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");
  let target = "";
  try {
    await requireAdminStaff();
    const upload = await readUpload(formData.get("sage_draft_file"));
    const extracted = upload.uploadedText ? extractBoxTotalsFromText(upload.uploadedText) : {};
    const overrides = manualOverrides(formData);
    if (!upload.uploadedText && Object.keys(overrides).length === 0) throw new Error("Upload the Sage VAT file or enter the Sage boxes manually.");
    const preview = withDerived({ ...extracted, ...overrides });
    const purpose = uploadPurpose(formData);
    const params = new URLSearchParams({ preview: "1", source_mode: upload.uploadedText ? "upload_preview" : "manual_preview", upload_purpose: purpose });
    const sageReturnReference = s(formData.get("sage_return_reference"));
    const sageSubmissionTimestamp = s(formData.get("sage_submission_timestamp"));
    if (sageReturnReference) params.set("sage_return_reference", sageReturnReference);
    if (sageSubmissionTimestamp) params.set("sage_submission_timestamp", sageSubmissionTimestamp);
    if (upload.uploadedFileSummary?.name) params.set("file_name", s(upload.uploadedFileSummary.name));
    for (const box of ALL) if (preview[box] !== undefined && preview[box] !== null) params.set(`box${box}`, preview[box]!.toFixed(2));
    const missing = missingRequired(preview);
    if (missing.length) params.set("missing", missing.join(","));
    target = `/internal/accounting-vat/returns/${runId}/sage-draft-import?${params.toString()}`;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Sage VAT preview failed.";
    redirect(`/internal/accounting-vat/returns/${runId}/sage-draft-import?vatError=${encodeURIComponent(message)}`);
  }
  redirect(target);
}

export async function importSageDraftVatReturnTotalsAction(formData: FormData) {
  const runId = s(formData.get("vat_return_run_id"));
  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");
  let snapshotId = "";
  try {
    const { supabase, staff } = await requireAdminStaff();
    const { data: run, error: runError } = await (supabase as any).from("vat_return_runs").select("id, period_start_date, period_end_date").eq("id", runId).maybeSingle();
    if (runError) throw new Error(runError.message);
    if (!run) throw new Error("VAT return run not found.");
    const upload = await readUpload(formData.get("sage_draft_file"));
    const extracted = upload.uploadedText ? extractBoxTotalsFromText(upload.uploadedText) : {};
    const overrides = manualOverrides(formData);
    if (!upload.uploadedText && Object.keys(overrides).length === 0) throw new Error("Upload the Sage draft VAT export or enter the Sage boxes manually.");
    const { boxes, warnings } = finalBoxes(extracted, overrides);
    const sourceMode = upload.uploadedText ? "sage_draft_upload_with_optional_manual_override" : "manual_sage_draft_totals_entry";
    const { data: snapshot, error: insertError } = await (supabase as any).from("vat_return_sage_reconstruction_snapshots").insert({
      vat_return_run_id: runId,
      period_start_date: s((run as Row).period_start_date),
      period_end_date: s((run as Row).period_end_date),
      status: "reconstructed",
      source_basis: "sage_draft_vat_return_totals_import_strict_total_for_box_v3",
      box1_gbp: boxes[1], box2_gbp: boxes[2], box3_gbp: boxes[3], box4_gbp: boxes[4], box5_gbp: boxes[5], box6_gbp: boxes[6], box7_gbp: boxes[7], box8_gbp: boxes[8], box9_gbp: boxes[9],
      sales_invoice_count: 0, sales_credit_note_count: 0, purchase_invoice_count: 0, purchase_credit_note_count: 0,
      source_counts: { source_mode: sourceMode, hydrated_sage_documents: 0 },
      source_summary: { version: "sage_draft_vat_return_totals_import_strict_total_for_box_v3", purpose: "Use Sage draft VAT return totals as the Sage pre-adjustment comparator. Extraction is fail-closed and only accepts exact Total for Box rows.", source_mode: sourceMode, uploaded_file: upload.uploadedFileSummary, extracted_boxes: extracted, manual_overrides: overrides, final_boxes: boxes, calculation_warnings: warnings },
      warning_notes: ["Sage draft VAT totals imported without invoice hydration.", "Parser is fail-closed: upload extraction only accepts exact Total for Box rows; otherwise admin must enter boxes manually.", ...warnings].join(" "),
      created_by_staff_id: staff.id,
    }).select("id").single();
    if (insertError) throw new Error(insertError.message || "Could not save Sage draft VAT totals snapshot.");
    snapshotId = s((snapshot as Row)?.id) || "1";
  } catch (error) {
    const message = error instanceof Error ? error.message : "Sage draft VAT totals import failed.";
    redirect(`/internal/accounting-vat/returns/${runId}/sage-draft-import?vatError=${encodeURIComponent(message)}`);
  }
  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);
  redirect(`/internal/accounting-vat/returns/${runId}?tab=summary&sageSnapshot=${encodeURIComponent(snapshotId)}`);
}

export async function recordFinalSageVatSubmissionEvidenceAction(formData: FormData) {
  const runId = s(formData.get("vat_return_run_id"));
  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");
  let target = "";
  try {
    const { supabase } = await requireAdminStaff();
    const sageReturnReference = s(formData.get("sage_return_reference"));
    if (!sageReturnReference) throw new Error("Enter the Sage return reference before recording final submission evidence.");
    const confirmed = s(formData.get("confirm_final_sage_submission")) === "yes";
    if (!confirmed) throw new Error("Confirm this is the final submitted Sage VAT return evidence before locking can be attempted.");
    const sageSubmissionTimestamp = finalSubmissionTimestamp(formData.get("sage_submission_timestamp"));
    const upload = await readUpload(formData.get("sage_draft_file"));
    const extracted = upload.uploadedText ? extractBoxTotalsFromText(upload.uploadedText) : {};
    const overrides = manualOverrides(formData);
    if (!upload.uploadedText && Object.keys(overrides).length === 0) throw new Error("Upload the final Sage VAT return evidence or enter the submitted Sage boxes manually.");
    const { boxes, warnings } = finalBoxes(extracted, overrides);
    const { data, error } = await (supabase as any).rpc("staff_record_vat_sage_submission_and_lock_v1", {
      p_vat_return_run_id: runId,
      p_sage_return_reference: sageReturnReference,
      p_sage_submitted_box1_gbp: boxes[1],
      p_sage_submitted_box2_gbp: boxes[2],
      p_sage_submitted_box3_gbp: boxes[3],
      p_sage_submitted_box4_gbp: boxes[4],
      p_sage_submitted_box5_gbp: boxes[5],
      p_sage_submitted_box6_gbp: boxes[6],
      p_sage_submitted_box7_gbp: boxes[7],
      p_sage_submitted_box8_gbp: boxes[8],
      p_sage_submitted_box9_gbp: boxes[9],
      p_sage_submission_timestamp: sageSubmissionTimestamp,
      p_evidence_url: null,
      p_evidence_json: {
        upload_purpose: "final_submission_evidence",
        uploaded_file: upload.uploadedFileSummary,
        extracted_boxes: extracted,
        manual_overrides: overrides,
        final_boxes: boxes,
        calculation_warnings: warnings,
        confirmation: "admin_confirmed_final_sage_submission_evidence",
      },
      p_tolerance_gbp: 0.01,
      p_notes: "Final Sage VAT submission evidence uploaded through Sage VAT upload page.",
    });
    if (error) throw new Error(error.message || "Could not record final Sage VAT submission evidence.");
    revalidatePath("/internal/accounting-vat");
    revalidatePath(`/internal/accounting-vat/returns/${runId}`);
    target = rpcMatched(data)
      ? `/internal/accounting-vat/returns/${runId}?tab=submission&vatSuccess=Final%20Sage%20submission%20matched%20and%20return%20locked`
      : `/internal/accounting-vat/returns/${runId}?tab=submission&vatError=Final%20Sage%20submission%20does%20not%20match%20platform%20expected%20boxes`;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Final Sage VAT submission evidence failed.";
    redirect(`/internal/accounting-vat/returns/${runId}/sage-draft-import?upload_purpose=final_submission_evidence&vatError=${encodeURIComponent(message)}`);
  }
  redirect(target);
}
