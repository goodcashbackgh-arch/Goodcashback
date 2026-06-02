"use server";

import { createHash } from "node:crypto";
import { inflateRawSync } from "node:zlib";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type BoxTotals = Partial<Record<1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9, number>>;
type Row = Record<string, unknown>;
type ZipEntry = { name: string; data: Buffer };

const REQUIRED_BOXES: Array<keyof BoxTotals> = [1, 4, 6, 7];
const OPTIONAL_ZERO_BOXES: Array<keyof BoxTotals> = [2, 8, 9];
const MAX_UPLOAD_BYTES = 2_000_000;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function money2(value: number): number {
  return Number(value.toFixed(2));
}

function parseMoney(value: unknown): number | null {
  const raw = text(value);
  if (!raw) return null;
  const negativeByBrackets = /^\s*\(.*\)\s*$/.test(raw);
  const cleaned = raw.replace(/,/g, "").replace(/[£$€\s()]/g, "").replace(/[^0-9.\-]/g, "");
  if (!cleaned || cleaned === "-" || cleaned === ".") return null;
  const parsed = Number(cleaned);
  if (!Number.isFinite(parsed)) return null;
  return money2(negativeByBrackets ? -Math.abs(parsed) : parsed);
}

function normalise(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9%]+/g, " ").replace(/\s+/g, " ").trim();
}

function parseCsvRows(input: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let inQuotes = false;

  for (let i = 0; i < input.length; i += 1) {
    const char = input[i];
    const next = input[i + 1];

    if (char === '"') {
      if (inQuotes && next === '"') {
        cell += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (!inQuotes && (char === "," || char === "\t")) {
      row.push(cell.trim());
      cell = "";
      continue;
    }

    if (!inQuotes && (char === "\n" || char === "\r")) {
      if (char === "\r" && next === "\n") i += 1;
      row.push(cell.trim());
      if (row.some(Boolean)) rows.push(row);
      row = [];
      cell = "";
      continue;
    }

    cell += char;
  }

  row.push(cell.trim());
  if (row.some(Boolean)) rows.push(row);
  return rows;
}

function decodeXml(value: string): string {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_match, code) => String.fromCharCode(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_match, code) => String.fromCharCode(parseInt(code, 16)));
}

function unzipEntries(buffer: Buffer): ZipEntry[] {
  let eocd = -1;
  const minOffset = Math.max(0, buffer.length - 65_557);
  for (let i = buffer.length - 22; i >= minOffset; i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error("Could not read XLSX file. Please upload a valid .xlsx file or enter the boxes manually.");

  const entryCount = buffer.readUInt16LE(eocd + 10);
  const centralOffset = buffer.readUInt32LE(eocd + 16);
  const entries: ZipEntry[] = [];
  let pointer = centralOffset;

  for (let index = 0; index < entryCount; index += 1) {
    if (buffer.readUInt32LE(pointer) !== 0x02014b50) break;
    const method = buffer.readUInt16LE(pointer + 10);
    const compressedSize = buffer.readUInt32LE(pointer + 20);
    const fileNameLength = buffer.readUInt16LE(pointer + 28);
    const extraLength = buffer.readUInt16LE(pointer + 30);
    const commentLength = buffer.readUInt16LE(pointer + 32);
    const localHeaderOffset = buffer.readUInt32LE(pointer + 42);
    const name = buffer.subarray(pointer + 46, pointer + 46 + fileNameLength).toString("utf8");

    const localFileNameLength = buffer.readUInt16LE(localHeaderOffset + 26);
    const localExtraLength = buffer.readUInt16LE(localHeaderOffset + 28);
    const dataStart = localHeaderOffset + 30 + localFileNameLength + localExtraLength;
    const raw = buffer.subarray(dataStart, dataStart + compressedSize);

    if (method === 0) {
      entries.push({ name, data: raw });
    } else if (method === 8) {
      entries.push({ name, data: inflateRawSync(raw) });
    }

    pointer += 46 + fileNameLength + extraLength + commentLength;
  }

  return entries;
}

function parseSharedStrings(xml: string): string[] {
  const strings: string[] = [];
  for (const si of xml.matchAll(/<si[\s\S]*?<\/si>/g)) {
    const textParts = Array.from(si[0].matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)).map((match) => decodeXml(match[1]));
    strings.push(textParts.join(""));
  }
  return strings;
}

function columnIndex(ref: string): number {
  const letters = ref.replace(/[^A-Z]/g, "");
  let total = 0;
  for (const letter of letters) total = total * 26 + (letter.charCodeAt(0) - 64);
  return Math.max(0, total - 1);
}

function cellText(attrs: string, body: string, sharedStrings: string[]): string {
  const type = attrs.match(/\bt="([^"]+)"/)?.[1] ?? "";
  if (type === "s") {
    const index = Number(body.match(/<v>([\s\S]*?)<\/v>/)?.[1] ?? "");
    return Number.isFinite(index) ? text(sharedStrings[index]) : "";
  }
  if (type === "inlineStr") {
    return Array.from(body.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)).map((match) => decodeXml(match[1])).join("");
  }
  return decodeXml(body.match(/<v>([\s\S]*?)<\/v>/)?.[1] ?? "");
}

function sheetXmlToText(xml: string, sharedStrings: string[]): string {
  const lines: string[] = [];
  for (const rowMatch of xml.matchAll(/<row\b[\s\S]*?<\/row>/g)) {
    const cells: string[] = [];
    for (const cellMatch of rowMatch[0].matchAll(/<c\b([^>]*)>([\s\S]*?)<\/c>/g)) {
      const attrs = cellMatch[1];
      const ref = attrs.match(/\br="([A-Z]+\d+)"/)?.[1] ?? "";
      const index = ref ? columnIndex(ref) : cells.length;
      cells[index] = cellText(attrs, cellMatch[2], sharedStrings);
    }
    if (cells.some((cell) => text(cell))) lines.push(cells.map((cell) => cell ?? "").join("\t"));
  }
  return lines.join("\n");
}

function xlsxToText(buffer: Buffer): string {
  const entries = unzipEntries(buffer);
  const byName = new Map(entries.map((entry) => [entry.name, entry.data]));
  const sharedStrings = byName.has("xl/sharedStrings.xml") ? parseSharedStrings(byName.get("xl/sharedStrings.xml")!.toString("utf8")) : [];
  const sheetTexts = entries
    .filter((entry) => /^xl\/worksheets\/sheet\d+\.xml$/i.test(entry.name))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((entry) => sheetXmlToText(entry.data.toString("utf8"), sharedStrings))
    .filter(Boolean);

  if (!sheetTexts.length) throw new Error("Could not find readable worksheets in the XLSX file. Enter the Sage boxes manually or export CSV from Sage.");
  return sheetTexts.join("\n");
}

function isXlsxFile(file: File): boolean {
  const name = file.name.toLowerCase();
  return name.endsWith(".xlsx") || file.type === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
}

function aliasBox(joined: string): keyof BoxTotals | null {
  if (/\bbox\s*1\b/.test(joined) || (joined.includes("vat due") && (joined.includes("sales") || joined.includes("outputs")))) return 1;
  if (/\bbox\s*2\b/.test(joined) || joined.includes("acquisitions from other ec") || joined.includes("acquisitions from other eu")) return 2;
  if (/\bbox\s*3\b/.test(joined) || joined.includes("total vat due")) return 3;
  if (/\bbox\s*4\b/.test(joined) || joined.includes("vat reclaimed") || joined.includes("vat reclaimable") || joined.includes("purchases and other inputs")) return 4;
  if (/\bbox\s*5\b/.test(joined) || joined.includes("net vat to pay") || joined.includes("net vat due")) return 5;
  if (/\bbox\s*6\b/.test(joined) || joined.includes("total value of sales") || joined.includes("value of all sales")) return 6;
  if (/\bbox\s*7\b/.test(joined) || joined.includes("total value of purchases") || joined.includes("value of all purchases")) return 7;
  if (/\bbox\s*8\b/.test(joined) || joined.includes("supplies of goods") || joined.includes("dispatches")) return 8;
  if (/\bbox\s*9\b/.test(joined) || joined.includes("acquisitions of goods")) return 9;
  return null;
}

function detectBox(cells: string[]): keyof BoxTotals | null {
  const joined = normalise(cells.join(" "));
  const explicit = joined.match(/\bbox\s*([1-9])\b/);
  if (explicit) return Number(explicit[1]) as keyof BoxTotals;

  const numericBox = cells.map(normalise).find((cell) => /^[1-9]$/.test(cell));
  const aliased = aliasBox(joined);
  if (numericBox && aliased) return Number(numericBox) as keyof BoxTotals;

  return aliased;
}

function moneyCandidateFromText(raw: string, box: keyof BoxTotals): number | null {
  const value = raw.trim();
  if (!value) return null;
  const simplified = normalise(value);
  if (simplified === String(box) || simplified === `box ${box}`) return null;

  const matches = Array.from(value.matchAll(/\(?\s*-?\s*£?\s*\d[\d,]*(?:\.\d{1,2})?\s*\)?/g)).map((match) => match[0]);
  for (const token of matches.reverse()) {
    const parsed = parseMoney(token);
    if (parsed === null) continue;
    const tokenLooksLikeBoxNumber = Math.abs(parsed) === box && !/[.,£()\-]/.test(token) && /box/i.test(value);
    if (!tokenLooksLikeBoxNumber) return parsed;
  }

  return null;
}

function extractBoxTotalsFromText(input: string): BoxTotals {
  const totals: BoxTotals = {};
  const rows = parseCsvRows(input);

  for (const row of rows) {
    const box = detectBox(row);
    if (!box) continue;

    const candidates = [...row].reverse();
    let amount: number | null = null;
    for (const cell of candidates) {
      amount = moneyCandidateFromText(cell, box);
      if (amount !== null) break;
    }
    if (amount === null) amount = moneyCandidateFromText(row.join(" "), box);
    if (amount !== null) totals[box] = amount;
  }

  return totals;
}

function manualBoxOverrides(formData: FormData): BoxTotals {
  const overrides: BoxTotals = {};
  for (let box = 1; box <= 9; box += 1) {
    const raw = text(formData.get(`box${box}_gbp`));
    if (!raw) continue;
    const parsed = parseMoney(raw);
    if (parsed === null) throw new Error(`Box ${box} manual amount is not a valid GBP value.`);
    overrides[box as keyof BoxTotals] = parsed;
  }
  return overrides;
}

function buildFinalBoxes(extracted: BoxTotals, overrides: BoxTotals) {
  const boxes: BoxTotals = { ...extracted, ...overrides };
  const warnings: string[] = [];

  for (const box of OPTIONAL_ZERO_BOXES) {
    if (boxes[box] === undefined || boxes[box] === null) boxes[box] = 0;
  }

  for (const box of REQUIRED_BOXES) {
    if (boxes[box] === undefined || boxes[box] === null) {
      throw new Error(`Missing Box ${box}. Upload a Sage draft export with that box or enter it manually.`);
    }
  }

  const computedBox3 = money2((boxes[1] ?? 0) + (boxes[2] ?? 0));
  const computedBox5 = money2(computedBox3 - (boxes[4] ?? 0));

  if (boxes[3] === undefined || boxes[3] === null) {
    boxes[3] = computedBox3;
  } else if (Math.abs((boxes[3] ?? 0) - computedBox3) > 0.01) {
    warnings.push(`Extracted Box 3 ${boxes[3]} does not equal Box 1 + Box 2 ${computedBox3}. Sage value was preserved.`);
  }

  if (boxes[5] === undefined || boxes[5] === null) {
    boxes[5] = computedBox5;
  } else if (Math.abs((boxes[5] ?? 0) - computedBox5) > 0.01) {
    warnings.push(`Extracted Box 5 ${boxes[5]} does not equal Box 3 - Box 4 ${computedBox5}. Sage value was preserved.`);
  }

  return { boxes: boxes as Required<BoxTotals>, warnings };
}

async function requireAdminStaff() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Login required.");
  const { data: staff, error } = await supabase.from("staff").select("id, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (error) throw new Error(error.message);
  if (!staff || text((staff as Row).role_type) !== "admin") throw new Error("Admin-only VAT import access required.");
  return { supabase, staff: staff as { id: string; role_type: string } };
}

export async function importSageDraftVatReturnTotalsAction(formData: FormData) {
  const runId = text(formData.get("vat_return_run_id"));
  if (!runId) redirect("/internal/accounting-vat?vatError=Missing%20VAT%20return%20run%20id");

  let snapshotId = "";

  try {
    const { supabase, staff } = await requireAdminStaff();
    const { data: run, error: runError } = await (supabase as any)
      .from("vat_return_runs")
      .select("id, period_start_date, period_end_date")
      .eq("id", runId)
      .maybeSingle();

    if (runError) throw new Error(runError.message);
    if (!run) throw new Error("VAT return run not found.");

    const uploaded = formData.get("sage_draft_file");
    let uploadedText = "";
    let uploadedFileSummary: Row | null = null;

    if (uploaded instanceof File && uploaded.size > 0) {
      if (uploaded.size > MAX_UPLOAD_BYTES) throw new Error("Sage draft file is too large. Export a simple VAT return XLSX/CSV/text file under 2MB.");
      const buffer = Buffer.from(await uploaded.arrayBuffer());
      uploadedText = isXlsxFile(uploaded) ? xlsxToText(buffer) : buffer.toString("utf8");
      uploadedFileSummary = {
        name: uploaded.name,
        type: uploaded.type || "unknown",
        size_bytes: uploaded.size,
        sha256: createHash("sha256").update(buffer).digest("hex"),
        parser: isXlsxFile(uploaded) ? "xlsx_openxml_minimal_v1" : "text_csv_tsv_v1",
      };
    }

    const extractedBoxes = uploadedText ? extractBoxTotalsFromText(uploadedText) : {};
    const overrides = manualBoxOverrides(formData);
    if (!uploadedText && Object.keys(overrides).length === 0) throw new Error("Upload the Sage draft VAT export or enter the Sage boxes manually.");

    const { boxes, warnings } = buildFinalBoxes(extractedBoxes, overrides);
    const sourceMode = uploadedText ? "sage_draft_upload_with_optional_manual_override" : "manual_sage_draft_totals_entry";

    const { data: snapshot, error: insertError } = await (supabase as any)
      .from("vat_return_sage_reconstruction_snapshots")
      .insert({
        vat_return_run_id: runId,
        period_start_date: text((run as Row).period_start_date),
        period_end_date: text((run as Row).period_end_date),
        status: "reconstructed",
        source_basis: "sage_draft_vat_return_totals_import_v1",
        box1_gbp: boxes[1],
        box2_gbp: boxes[2],
        box3_gbp: boxes[3],
        box4_gbp: boxes[4],
        box5_gbp: boxes[5],
        box6_gbp: boxes[6],
        box7_gbp: boxes[7],
        box8_gbp: boxes[8],
        box9_gbp: boxes[9],
        sales_invoice_count: 0,
        sales_credit_note_count: 0,
        purchase_invoice_count: 0,
        purchase_credit_note_count: 0,
        source_counts: {
          source_mode: sourceMode,
          hydrated_sage_documents: 0,
        },
        source_summary: {
          version: "sage_draft_vat_return_totals_import_v1",
          purpose: "Use Sage draft VAT return totals as the Sage pre-adjustment comparator. Detailed invoice/GL evidence remains in Sage.",
          source_mode: sourceMode,
          uploaded_file: uploadedFileSummary,
          extracted_boxes: extractedBoxes,
          manual_overrides: overrides,
          final_boxes: boxes,
          calculation_warnings: warnings,
        },
        warning_notes: [
          "Sage draft VAT totals imported without invoice hydration. This snapshot is for Sage-vs-platform reconciliation before approved platform VAT adjustment journals.",
          "Line detail remains in Sage; upload/entry should be checked by admin against the Sage draft return before submission.",
          ...warnings,
        ].join(" "),
        created_by_staff_id: staff.id,
      })
      .select("id")
      .single();

    if (insertError) throw new Error(insertError.message || "Could not save Sage draft VAT totals snapshot.");
    snapshotId = text((snapshot as Row)?.id) || "1";
  } catch (error) {
    const message = error instanceof Error ? error.message : "Sage draft VAT totals import failed.";
    redirect(`/internal/accounting-vat/returns/${runId}/sage-draft-import?vatError=${encodeURIComponent(message)}`);
  }

  revalidatePath("/internal/accounting-vat");
  revalidatePath(`/internal/accounting-vat/returns/${runId}`);
  redirect(`/internal/accounting-vat/returns/${runId}?tab=summary&sageDraftImported=${encodeURIComponent(snapshotId)}`);
}
