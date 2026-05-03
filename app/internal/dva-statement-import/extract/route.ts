import { createHash } from "crypto";
import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type Batch = {
  id: string;
  importer_id: string;
  source_bank: string;
  statement_period_from: string;
  statement_period_to: string;
  local_ccy: string;
  source_file_url: string;
  original_filename: string | null;
  detected_file_type: string;
  parser_route: string;
  default_card_markup_pct: number | string | null;
  status: string;
};

type DraftRow = {
  rawText: string;
  rawJson?: Record<string, unknown>;
  statementDate: string | null;
  transactionDate: string | null;
  direction: "in" | "out" | null;
  transactionType: string;
  amountLocal: number | null;
  balanceAfter: number | null;
  cardLast4: string | null;
  merchantRaw: string | null;
  merchantNormalised: string | null;
  bankReference: string | null;
  authOrSettlementRef: string | null;
  transactionFamilyRef: string | null;
  confidence: "high" | "medium" | "low";
  errorCode?: string | null;
  errorMessage?: string | null;
};

function redirectTo(request: Request, params: Record<string, string>) {
  const url = new URL("/internal/dva-statement-import/extract", new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function normaliseMerchant(value: string | null) {
  const raw = cleanText(value).toLowerCase();
  if (!raw) return null;
  if (raw.includes("sharkninja") || raw.includes("shark ninja") || raw.includes("ninja")) return "sharkninja";
  if (raw.includes("zara")) return "zara";
  if (raw.includes("asos")) return "asos";
  return raw.replace(/[^a-z0-9]+/g, "").slice(0, 80) || null;
}

function parseDate(value: string | null | undefined) {
  const raw = cleanText(value);
  if (!raw) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) return raw;
  const match = raw.match(/(\d{1,2})[-\s]([A-Za-z]{3})[-\s](\d{4})/);
  if (!match) return null;
  const monthMap: Record<string, string> = {
    jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
    jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12",
  };
  const dd = match[1].padStart(2, "0");
  const mm = monthMap[match[2].slice(0, 3).toLowerCase()];
  return mm ? `${match[3]}-${mm}-${dd}` : null;
}

function parseMoney(value: unknown) {
  const raw = cleanText(value).replace(/£|GHS|GBP|,/gi, "");
  const match = raw.match(/-?\d+(?:\.\d{1,2})?/);
  if (!match) return null;
  const parsed = Number(match[0]);
  return Number.isFinite(parsed) ? Math.round(parsed * 100) / 100 : null;
}

function moneyValues(value: string) {
  return Array.from(value.matchAll(/-?\d{1,3}(?:,\d{3})*(?:\.\d{2})|-?\d+\.\d{2}/g))
    .map((m) => parseMoney(m[0]))
    .filter((n): n is number => n !== null);
}

function extractCardLast4(raw: string) {
  return raw.match(/\*+(\d{4})/)?.[1] ?? null;
}

function extractReference(raw: string) {
  const refs = Array.from(raw.matchAll(/\b[A-Z0-9]{8,}\b/g)).map((m) => m[0]);
  return refs.length ? refs[refs.length - 1] : null;
}

function extractMerchant(raw: string) {
  const known = raw.match(/\b(Zara\.com|asos\.?com|SharkNinja[^\n\r]*|Ninja[^\n\r]*)/i)?.[1];
  if (known) return known.replace(/\s+\d.*$/, "").trim();
  const cardLine = raw.match(/\d{6}\*+\d{4}\s+(?:\d+\s+)?([^\n\r]+)/);
  if (cardLine?.[1]) return cardLine[1].trim();
  return null;
}

function classify(raw: string, amount: number | null): { direction: "in" | "out" | null; type: string } {
  const lower = raw.toLowerCase();
  if (lower.includes("refund") || lower.includes("reversal") || lower.includes("settlement refund")) {
    return { direction: "in", type: "retailer_refund_candidate" };
  }
  if (lower.includes("momo") || lower.includes("gip") || lower.includes("fee") || (amount !== null && amount <= 15 && lower.includes("transfer"))) {
    return { direction: "out", type: "bank_fee_candidate" };
  }
  if (lower.includes("transfer to")) return { direction: "out", type: "transfer_candidate" };
  if (lower.includes("transfer") || lower.includes("ib oc")) return { direction: "in", type: "inbound_funding_candidate" };
  if (lower.includes("zara") || lower.includes("asos") || lower.includes("ninja") || lower.includes("posv") || lower.includes("visa")) {
    return { direction: "out", type: "supplier_purchase_candidate" };
  }
  return { direction: null, type: "unmatched_candidate" };
}

function fingerprint(batch: Batch, row: DraftRow, rowNumber: number) {
  const basis = [
    batch.importer_id,
    batch.source_bank,
    row.statementDate,
    row.transactionDate,
    row.direction,
    row.amountLocal,
    row.balanceAfter,
    batch.local_ccy,
    row.cardLast4,
    row.merchantNormalised,
    row.bankReference,
    row.authOrSettlementRef,
    row.rawText.slice(0, 180),
    rowNumber,
  ].join("|");
  return createHash("sha256").update(basis).digest("hex");
}

function parseCsvLine(line: string) {
  const result: string[] = [];
  let current = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"' && line[i + 1] === '"') {
      current += '"';
      i += 1;
    } else if (char === '"') {
      quoted = !quoted;
    } else if (char === "," && !quoted) {
      result.push(current.trim());
      current = "";
    } else {
      current += char;
    }
  }
  result.push(current.trim());
  return result;
}

function normaliseHeader(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

function pick(row: Record<string, string>, names: string[]) {
  for (const name of names) {
    if (row[name] !== undefined && row[name] !== "") return row[name];
  }
  return "";
}

function parseCsvRows(raw: string): DraftRow[] {
  const lines = raw.split(/\r?\n/).filter((line) => line.trim());
  if (lines.length < 2) return [];
  const headers = parseCsvLine(lines[0]).map(normaliseHeader);
  return lines.slice(1).map((line) => {
    const values = parseCsvLine(line);
    const row = Object.fromEntries(headers.map((header, index) => [header, values[index] ?? ""]));
    const description = pick(row, ["description", "reference", "details", "narration", "transaction_details", "merchant", "memo"]);
    const debit = parseMoney(pick(row, ["debit", "withdrawal", "paid_out", "out"]));
    const credit = parseMoney(pick(row, ["credit", "deposit", "paid_in", "in"]));
    const genericAmount = parseMoney(pick(row, ["amount", "transaction_amount", "value"]));
    const amount = debit ?? credit ?? (genericAmount !== null ? Math.abs(genericAmount) : null);
    const inferred = classify(description, amount);
    const direction = debit !== null ? "out" : credit !== null ? "in" : genericAmount !== null && genericAmount < 0 ? "out" : inferred.direction;
    const merchant = pick(row, ["merchant", "retailer", "payee", "counterparty"]) || extractMerchant(description);
    return {
      rawText: line,
      rawJson: row,
      statementDate: parseDate(pick(row, ["statement_date", "date", "posting_date", "book_date"])) ?? null,
      transactionDate: parseDate(pick(row, ["transaction_date", "value_date", "effective_date"])) ?? null,
      direction,
      transactionType: direction === "in" && inferred.type === "supplier_purchase_candidate" ? "inbound_funding_candidate" : inferred.type,
      amountLocal: amount,
      balanceAfter: parseMoney(pick(row, ["balance", "running_balance", "balance_after"])),
      cardLast4: pick(row, ["card_last4", "card_last_4"]) || extractCardLast4(description),
      merchantRaw: merchant,
      merchantNormalised: normaliseMerchant(merchant),
      bankReference: pick(row, ["bank_reference", "reference_number", "transaction_id"]) || null,
      authOrSettlementRef: pick(row, ["auth_ref", "auth_id", "settlement_ref"]) || extractReference(description),
      transactionFamilyRef: pick(row, ["family_ref", "group_ref"]) || null,
      confidence: "medium",
    };
  });
}

function parseTextBlocks(raw: string): DraftRow[] {
  const lines = raw.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const blocks: string[][] = [];
  let current: string[] = [];
  const dateOnly = /^(\d{1,2}[-\s][A-Za-z]{3}[-\s]\d{4}|\d{4}-\d{2}-\d{2})$/;
  for (const line of lines) {
    if (dateOnly.test(line) && current.length) {
      blocks.push(current);
      current = [line];
    } else {
      current.push(line);
    }
  }
  if (current.length) blocks.push(current);

  return blocks.map((block) => {
    const blockText = block.join("\n");
    const statementDate = parseDate(block[0]);
    const datedLine = [...block].reverse().find((line) => parseDate(line));
    const transactionDate = parseDate(datedLine ?? block[0]);
    const amountLine = [...block].reverse().find((line) => moneyValues(line).length >= 1) ?? "";
    const amounts = moneyValues(amountLine);
    const amount = amounts[0] ?? null;
    const balance = amounts.length > 1 ? amounts[1] : null;
    const merchant = extractMerchant(blockText);
    const inferred = classify(blockText, amount);
    return {
      rawText: blockText,
      rawJson: { block },
      statementDate,
      transactionDate,
      direction: inferred.direction,
      transactionType: inferred.type,
      amountLocal: amount,
      balanceAfter: balance,
      cardLast4: extractCardLast4(blockText),
      merchantRaw: merchant,
      merchantNormalised: normaliseMerchant(merchant),
      bankReference: block.find((line) => /^\d{10,}$/.test(line.replace(/\s+/g, ""))) ?? null,
      authOrSettlementRef: extractReference(blockText),
      transactionFamilyRef: null,
      confidence: merchant && amount && statementDate ? "medium" : "low",
    };
  });
}

function withFx(row: DraftRow, batch: Batch, manualFxRate: number | null): DraftRow & { fxRate: number | null; gbpAmount: number | null } {
  const localCcy = cleanText(batch.local_ccy).toUpperCase();
  const fxRate = localCcy === "GBP" ? 1 : manualFxRate;
  const amount = row.amountLocal;
  const gbpAmount = amount !== null && fxRate && fxRate > 0
    ? Math.round((localCcy === "GBP" ? amount : amount / fxRate) * 100) / 100
    : null;
  return { ...row, fxRate, gbpAmount };
}

function validation(row: ReturnType<typeof withFx>) {
  if (!row.statementDate) return { code: "missing_date", message: "Statement date could not be parsed." };
  if (!row.direction) return { code: "unknown_direction", message: "Statement direction could not be classified as IN or OUT." };
  if (row.amountLocal === null || row.amountLocal <= 0) return { code: "invalid_amount", message: "Transaction amount could not be parsed." };
  if (!row.fxRate || row.fxRate <= 0 || row.gbpAmount === null || row.gbpAmount <= 0) return { code: "missing_fx_rate", message: "GBP equivalent could not be calculated. Provide a valid extraction FX rate for non-GBP statements." };
  return { code: row.errorCode ?? null, message: row.errorMessage ?? null };
}

async function stageRow(supabase: Awaited<ReturnType<typeof createClient>>, batch: Batch, row: DraftRow, rowNumber: number, manualFxRate: number | null) {
  const fxRow = withFx(row, batch, manualFxRate);
  const check = validation(fxRow);
  const { error } = await supabase.rpc("staff_stage_dva_statement_import_row", {
    p_import_batch_id: batch.id,
    p_source_row_number: rowNumber,
    p_source_page_number: null,
    p_raw_text: row.rawText || `Parsed row ${rowNumber}`,
    p_raw_json: fxRow.rawJson ?? { parser: "statement_import_v1" },
    p_statement_date: fxRow.statementDate,
    p_transaction_date: fxRow.transactionDate,
    p_direction: fxRow.direction,
    p_transaction_type_candidate: fxRow.transactionType,
    p_amount_local_ccy: fxRow.amountLocal,
    p_balance_after_local_ccy: fxRow.balanceAfter,
    p_local_ccy: batch.local_ccy,
    p_fx_rate_applied: fxRow.fxRate,
    p_card_markup_pct_applied: Number(batch.default_card_markup_pct ?? 0),
    p_amount_gbp_equivalent: fxRow.gbpAmount,
    p_card_last4: fxRow.cardLast4,
    p_merchant_raw: fxRow.merchantRaw,
    p_merchant_normalised: fxRow.merchantNormalised,
    p_bank_reference: fxRow.bankReference,
    p_auth_or_settlement_ref: fxRow.authOrSettlementRef,
    p_transaction_family_ref: fxRow.transactionFamilyRef,
    p_parser_confidence: fxRow.confidence,
    p_error_code: check.code,
    p_error_message: check.message,
    p_statement_line_fingerprint_hash: fingerprint(batch, fxRow, rowNumber),
  });
  if (error) throw new Error(error.message);
}

async function stageUnsupportedRow(supabase: Awaited<ReturnType<typeof createClient>>, batch: Batch, message: string) {
  await stageRow(supabase, batch, {
    rawText: message,
    rawJson: { unsupported: true, detected_file_type: batch.detected_file_type, parser_route: batch.parser_route },
    statementDate: batch.statement_period_from,
    transactionDate: batch.statement_period_from,
    direction: null,
    transactionType: "unmatched_candidate",
    amountLocal: null,
    balanceAfter: null,
    cardLast4: null,
    merchantRaw: null,
    merchantNormalised: null,
    bankReference: null,
    authOrSettlementRef: null,
    transactionFamilyRef: null,
    confidence: "low",
    errorCode: "parser_not_ready",
    errorMessage: message,
  }, 1, null);
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const batchId = cleanText(formData.get("import_batch_id"));
  const fxRaw = cleanText(formData.get("manual_fx_rate"));
  const manualFxRate = fxRaw ? Number(fxRaw) : null;

  if (!batchId) return redirectTo(request, { import_error: "Missing import batch id." });
  if (manualFxRate !== null && (!Number.isFinite(manualFxRate) || manualFxRate <= 0)) {
    return redirectTo(request, { import_error: "Extraction FX rate must be greater than zero." });
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectTo(request, { import_error: "Please sign in again before extracting statement rows." });

  const { data: batch, error: batchError } = await supabase
    .from("dva_statement_import_batches")
    .select("id, importer_id, source_bank, statement_period_from, statement_period_to, local_ccy, source_file_url, original_filename, detected_file_type, parser_route, default_card_markup_pct, status")
    .eq("id", batchId)
    .maybeSingle();

  if (batchError || !batch) return redirectTo(request, { import_error: batchError?.message ?? "Import batch not found." });
  const typedBatch = batch as Batch;
  if (["committed", "voided"].includes(typedBatch.status)) return redirectTo(request, { import_error: `Cannot extract rows for batch in status ${typedBatch.status}.` });

  try {
    if (typedBatch.detected_file_type === "pdf") {
      await stageUnsupportedRow(supabase, typedBatch, "PDF statement OCR is gated. Configure and test the Mindee statement model before consuming pages; CSV/text extraction is active now.");
      return redirectTo(request, { import_success: "PDF batch staged with OCR-gated row-level error. No Mindee pages consumed.", batch_id: batchId });
    }

    if (typedBatch.detected_file_type === "xlsx") {
      await stageUnsupportedRow(supabase, typedBatch, "XLSX direct parsing needs a spreadsheet parser dependency. Export CSV for this batch or add XLSX parser support next.");
      return redirectTo(request, { import_success: "XLSX batch staged with parser-needed row-level error.", batch_id: batchId });
    }

    const fileResponse = await fetch(typedBatch.source_file_url, { cache: "no-store" });
    if (!fileResponse.ok) throw new Error(`Could not fetch uploaded statement file (${fileResponse.status}).`);
    const raw = await fileResponse.text();
    const drafts = typedBatch.detected_file_type === "csv" ? parseCsvRows(raw) : parseTextBlocks(raw);

    if (drafts.length === 0) {
      await stageUnsupportedRow(supabase, typedBatch, "No transaction rows could be parsed from the uploaded statement file.");
      return redirectTo(request, { import_success: "Extraction ran but no usable rows were found; row-level error staged.", batch_id: batchId });
    }

    for (let index = 0; index < drafts.length; index += 1) {
      await stageRow(supabase, typedBatch, drafts[index], index + 1, manualFxRate);
    }

    return redirectTo(request, { import_success: `Extracted and staged ${drafts.length} row(s). Review clean/errors/duplicates before commit.`, batch_id: batchId });
  } catch (error) {
    return redirectTo(request, { import_error: error instanceof Error ? error.message : "Statement extraction failed." });
  }
}
