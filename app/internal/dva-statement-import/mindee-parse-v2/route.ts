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
  default_card_markup_pct: number | string | null;
  status: string;
  mindee_statement_ocr_status: string | null;
  mindee_statement_raw_json: unknown;
};

type Direction = "in" | "out" | null;

type DraftRow = {
  rawText: string;
  rawJson?: Record<string, unknown>;
  statementDate: string | null;
  transactionDate: string | null;
  direction: Direction;
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

function redirectToImport(request: Request, params: Record<string, string>) {
  const url = new URL("/internal/dva-statement-import", new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function parseDate(value: unknown) {
  const raw = cleanText(value);
  if (!raw) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) return raw;
  const slash = raw.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})$/);
  if (slash) {
    const dd = slash[1].padStart(2, "0");
    const mm = slash[2].padStart(2, "0");
    const yyyy = slash[3].length === 2 ? `20${slash[3]}` : slash[3];
    return `${yyyy}-${mm}-${dd}`;
  }
  const named = raw.match(/(\d{1,2})[-\s]([A-Za-z]{3})[-\s](\d{4})/);
  if (!named) return null;
  const monthMap: Record<string, string> = {
    jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
    jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12",
  };
  const mm = monthMap[named[2].slice(0, 3).toLowerCase()];
  return mm ? `${named[3]}-${mm}-${named[1].padStart(2, "0")}` : null;
}

function numberValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return Math.round(value * 100) / 100;
  if (typeof value === "string" && value.trim()) {
    const cleaned = value.replace(/£|GHS|GBP|,/gi, "");
    const parsed = Number(cleaned);
    if (Number.isFinite(parsed)) return Math.round(parsed * 100) / 100;
    const match = cleaned.match(/-?\d+(?:\.\d{1,2})?/);
    if (match) {
      const n = Number(match[0]);
      return Number.isFinite(n) ? Math.round(n * 100) / 100 : null;
    }
  }
  return null;
}

function getObject(value: unknown) {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    const obj = getObject(current);
    if (!obj) return null;
    current = obj[key];
  }
  return current ?? null;
}

function asArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  const obj = getObject(value);
  if (!obj) return [];
  for (const key of ["objectItems", "object_items", "items", "values", "simpleItems", "simple_items"]) {
    if (Array.isArray(obj[key])) return obj[key] as unknown[];
  }
  return [];
}

function normaliseFieldKey(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

function valueFromField(field: unknown) {
  const obj = getObject(field);
  if (!obj) return field;
  for (const key of ["stringValue", "numberValue", "booleanValue", "dateValue", "string_value", "number_value", "rawValue", "raw_value", "value", "content", "text"]) {
    if (obj[key] !== undefined && obj[key] !== null && obj[key] !== "") return obj[key];
  }
  return null;
}

function valueFromObjectByName(obj: Record<string, unknown>, name: string) {
  const wanted = normaliseFieldKey(name);
  if (obj[name] !== undefined) return valueFromField(obj[name]);
  for (const [key, value] of Object.entries(obj)) {
    if (normaliseFieldKey(key) === wanted) return valueFromField(value);
  }
  return null;
}

function fieldFromItem(item: unknown, name: string) {
  const obj = getObject(item);
  if (!obj) return null;

  const direct = valueFromObjectByName(obj, name);
  if (direct !== null) return direct;

  for (const parentKey of ["simpleFields", "simple_fields", "fields", "field_values"]) {
    const parent = getObject(obj[parentKey]);
    if (!parent) continue;
    const value = valueFromObjectByName(parent, name);
    if (value !== null) return value;
  }

  const arrays = [obj.simpleFields, obj.simple_fields, obj.fields].filter(Array.isArray) as unknown[][];
  for (const arr of arrays) {
    for (const entry of arr) {
      const entryObj = getObject(entry);
      const entryName = cleanText(entryObj?.name ?? entryObj?.field_name ?? entryObj?.key);
      if (normaliseFieldKey(entryName) === normaliseFieldKey(name)) return valueFromField(entryObj?.value ?? entryObj);
    }
  }

  return null;
}

function fieldFromItemAny(item: unknown, names: string[]) {
  for (const name of names) {
    const value = fieldFromItem(item, name);
    if (value !== null && value !== undefined && value !== "") return value;
  }
  return null;
}

function extractTransactions(raw: unknown) {
  const fields = getByPath(raw, ["inference", "result", "fields"])
    ?? getByPath(raw, ["document", "inference", "result", "fields"])
    ?? getByPath(raw, ["result", "fields"])
    ?? getByPath(raw, ["fields"]);

  const listField = getByPath(fields, ["list_of_transactions"])
    ?? getByPath(fields, ["transactions"])
    ?? getByPath(fields, ["transaction_lines"]);

  return asArray(listField);
}

function extractRawText(raw: unknown) {
  return cleanText(
    getByPath(raw, ["inference", "result", "rawText"])
    ?? getByPath(raw, ["inference", "result", "raw_text"])
    ?? getByPath(raw, ["result", "rawText"])
    ?? getByPath(raw, ["result", "raw_text"])
  );
}

function normaliseMerchant(value: string | null) {
  const raw = cleanText(value).toLowerCase();
  if (!raw) return null;
  if (raw.includes("sharkninja") || raw.includes("shark ninja") || raw.includes("ninja")) return "sharkninja";
  if (raw.includes("zara")) return "zara";
  if (raw.includes("asos")) return "asos";
  if (raw.includes("h&m") || raw.includes("hm.com") || raw.includes("hennes")) return "hm";
  if (raw.includes("riverisland") || raw.includes("river island")) return "riverisland";
  return raw.replace(/[^a-z0-9]+/g, "").slice(0, 80) || null;
}

function merchantFromDescription(description: string) {
  const known = description.match(/\b(Zara\.?com|asos\.?com|SharkNinja[^\d\n\r]*|Ninja[^\d\n\r]*|H\s*&\s*M[^\d\n\r]*|HM\.com|River\s*Island[^\d\n\r]*)/i)?.[1];
  if (known) return known.trim();
  const text = cleanText(description).replace(/\s+/g, " ");
  return text.length > 100 ? text.slice(0, 100) : text || null;
}

function extractReference(description: string) {
  const refs = Array.from(description.matchAll(/\b(?=[A-Z0-9]*\d)[A-Z0-9]{8,}\b/gi)).map((m) => m[0]);
  return refs.length ? refs[refs.length - 1] : null;
}

function normaliseMindeeDirection(value: unknown): Direction {
  const raw = cleanText(value).toLowerCase();
  if (!raw || raw === "unknown") return null;
  if (["credit", "cr", "in", "inflow", "deposit", "paid_in"].includes(raw)) return "in";
  if (["debit", "dr", "out", "outflow", "withdrawal", "paid_out"].includes(raw)) return "out";
  if (raw.includes("credit")) return "in";
  if (raw.includes("debit")) return "out";
  return null;
}

function looksLikeMerchantCardLine(description: string) {
  const lower = description.toLowerCase();
  if (lower.includes("pos") || lower.includes("visa") || lower.includes("mastercard") || lower.includes("card") || lower.includes("****")) return true;
  if (lower.includes(".com") || lower.includes(" gb") || lower.includes(" london") || lower.includes(" leeds")) return true;
  if (lower.includes("zara") || lower.includes("asos") || lower.includes("ninja") || lower.includes("sharkninja") || lower.includes("h&m") || lower.includes("river")) return true;
  return false;
}

function classify(description: string, explicitDirection: Direction): { direction: Direction; type: string } {
  const lower = description.toLowerCase();
  const isFee = lower.includes("momo") || lower.includes("gip") || lower.includes("fee") || lower.includes("charge");
  const isRefund = lower.includes("refund") || lower.includes("reversal") || lower.includes("settlement refund");
  const isBankToWallet = lower.includes("bank to wallet");
  const isWalletToBank = lower.includes("wallet to bank");
  const isInboundFundingText = lower.includes("transfer from") || lower.includes("pmt") || lower.includes("payment") || lower.includes("shopping") || lower.includes("deposit") || lower.includes("ib oc");
  const isOutboundTransferText = lower.includes("transfer to") || isBankToWallet;
  const isMerchantCardLine = looksLikeMerchantCardLine(description);

  if (explicitDirection === "in") {
    if (isRefund) return { direction: "in", type: "retailer_refund_candidate" };
    return { direction: "in", type: "inbound_funding_candidate" };
  }

  if (explicitDirection === "out") {
    if (isFee) return { direction: "out", type: "bank_fee_candidate" };
    if (isOutboundTransferText) return { direction: "out", type: "transfer_candidate" };
    return { direction: "out", type: "supplier_purchase_candidate" };
  }

  if (isWalletToBank || isInboundFundingText) return { direction: "in", type: "inbound_funding_candidate" };
  if (isFee) return { direction: "out", type: "bank_fee_candidate" };
  if (isOutboundTransferText) return { direction: "out", type: "transfer_candidate" };
  if (isRefund) return { direction: "in", type: "retailer_refund_candidate" };
  if (isMerchantCardLine) return { direction: "out", type: "supplier_purchase_candidate" };
  return { direction: null, type: "unmatched_candidate" };
}

function fingerprint(batch: Batch, row: DraftRow) {
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
  ].join("|");
  return createHash("sha256").update(basis).digest("hex");
}

function draftFromMindeeItem(item: unknown, batch: Batch): DraftRow {
  const description = cleanText(
    fieldFromItemAny(item, ["description", "details", "label", "transaction_description"])
  );
  const postingDate = parseDate(fieldFromItemAny(item, ["date", "posting_date", "book_date"]));
  const valueDate = parseDate(fieldFromItemAny(item, ["value_date", "transaction_date", "processed_date"]));
  const debitAmount = numberValue(fieldFromItemAny(item, ["debit_amount", "debit", "withdrawal", "paid_out"]));
  const creditAmount = numberValue(fieldFromItemAny(item, ["credit_amount", "credit", "deposit", "paid_in"]));
  const genericAmount = numberValue(fieldFromItemAny(item, ["amount", "transaction_amount", "value"]));
  const explicitDirection = normaliseMindeeDirection(fieldFromItemAny(item, ["direction", "transaction_direction", "debit_credit", "type"]));
  const amountLocal = debitAmount !== null && debitAmount > 0
    ? debitAmount
    : creditAmount !== null && creditAmount > 0
      ? creditAmount
      : genericAmount !== null
        ? Math.abs(genericAmount)
        : null;
  const direction = explicitDirection
    ?? (debitAmount !== null && debitAmount > 0 ? "out" : null)
    ?? (creditAmount !== null && creditAmount > 0 ? "in" : null)
    ?? (genericAmount !== null && genericAmount < 0 ? "out" : null);
  const inferred = classify(description, direction);
  const reference = cleanText(fieldFromItemAny(item, ["reference", "ref", "ref_chq_no", "ref_chq", "cheque_no", "check_number", "transaction_reference", "bank_reference"])) || extractReference(description);
  const familyRef = cleanText(fieldFromItemAny(item, ["transaction_id", "family_ref", "auth_ref", "settlement_ref", "authorization_code"])) || null;
  const merchant = merchantFromDescription(description);
  const merchantRaw = inferred.type === "supplier_purchase_candidate" || inferred.type === "retailer_refund_candidate"
    ? merchant
    : (description ? description.slice(0, 100) : null);
  const merchantNormalised = inferred.type === "supplier_purchase_candidate" || inferred.type === "retailer_refund_candidate"
    ? normaliseMerchant(merchant)
    : null;

  return {
    rawText: description || JSON.stringify(item).slice(0, 1000),
    rawJson: getObject(item) ?? { item },
    statementDate: postingDate ?? valueDate ?? batch.statement_period_from,
    transactionDate: valueDate ?? postingDate,
    direction: inferred.direction,
    transactionType: inferred.type,
    amountLocal,
    balanceAfter: numberValue(fieldFromItemAny(item, ["balance_after", "balance", "balance_amount", "running_balance"])),
    cardLast4: description.match(/\*+(\d{4})/)?.[1] ?? null,
    merchantRaw,
    merchantNormalised,
    bankReference: reference,
    authOrSettlementRef: familyRef ?? reference,
    transactionFamilyRef: familyRef,
    confidence: (postingDate || valueDate) && amountLocal !== null && description ? "high" : "low",
  };
}

function withFx(row: DraftRow, batch: Batch, manualFxRate: number | null): DraftRow & { fxRate: number | null; gbpAmount: number | null } {
  const localCcy = cleanText(batch.local_ccy).toUpperCase();
  const fxRate = localCcy === "GBP" ? 1 : manualFxRate;
  const gbpAmount = row.amountLocal !== null && fxRate && fxRate > 0
    ? Math.round((localCcy === "GBP" ? row.amountLocal : row.amountLocal / fxRate) * 100) / 100
    : null;
  return { ...row, fxRate, gbpAmount };
}

function validation(row: ReturnType<typeof withFx>) {
  if (row.errorCode) return { code: row.errorCode, message: row.errorMessage ?? row.errorCode };
  if (!row.statementDate) return { code: "missing_date", message: "Statement date could not be parsed." };
  if (!row.direction) return { code: "unknown_direction", message: "Statement direction could not be classified as IN or OUT." };
  if (row.amountLocal === null || row.amountLocal <= 0) return { code: "invalid_amount", message: "Transaction amount could not be parsed from Mindee result." };
  if (!row.fxRate || row.fxRate <= 0 || row.gbpAmount === null || row.gbpAmount <= 0) return { code: "missing_fx_rate", message: "GBP equivalent could not be calculated. Provide a valid FX rate for non-GBP statements." };
  return { code: row.errorCode ?? null, message: row.errorMessage ?? null };
}

async function stageRow(supabase: Awaited<ReturnType<typeof createClient>>, batch: Batch, row: DraftRow, rowNumber: number, manualFxRate: number | null) {
  const fxRow = withFx(row, batch, manualFxRate);
  const check = validation(fxRow);
  const { error } = await supabase.rpc("staff_stage_dva_statement_import_row", {
    p_import_batch_id: batch.id,
    p_source_row_number: rowNumber,
    p_source_page_number: null,
    p_raw_text: fxRow.rawText || `Mindee parsed row ${rowNumber}`,
    p_raw_json: fxRow.rawJson ?? { parser: "mindee_statement_v2_flexible" },
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
    p_statement_line_fingerprint_hash: fingerprint(batch, fxRow),
  });
  if (error) throw new Error(error.message);
}

async function stageParserError(supabase: Awaited<ReturnType<typeof createClient>>, batch: Batch, message: string) {
  await stageRow(supabase, batch, {
    rawText: message,
    rawJson: { parser: "mindee_statement_v2_flexible", rawTextSample: extractRawText(batch.mindee_statement_raw_json).slice(0, 1000) },
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
    errorCode: "mindee_parser_no_transactions",
    errorMessage: message,
  }, 1, null);
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const importBatchId = cleanText(formData.get("import_batch_id"));
  const fxRaw = cleanText(formData.get("manual_fx_rate"));
  const manualFxRate = fxRaw ? Number(fxRaw) : null;

  if (!importBatchId) return redirectToImport(request, { import_error: "Missing import batch id for Mindee parse." });
  if (manualFxRate !== null && (!Number.isFinite(manualFxRate) || manualFxRate <= 0)) {
    return redirectToImport(request, { import_error: "Mindee parse FX rate must be greater than zero." });
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectToImport(request, { import_error: "Please sign in again before parsing statement OCR." });

  const { data: batch, error: batchError } = await supabase
    .from("dva_statement_import_batches")
    .select("id, importer_id, source_bank, statement_period_from, statement_period_to, local_ccy, default_card_markup_pct, status, mindee_statement_ocr_status, mindee_statement_raw_json")
    .eq("id", importBatchId)
    .maybeSingle();

  if (batchError || !batch) return redirectToImport(request, { import_error: batchError?.message ?? "Statement import batch not found." });
  const typedBatch = batch as Batch;
  if (typedBatch.mindee_statement_ocr_status !== "completed" || !typedBatch.mindee_statement_raw_json) {
    return redirectToImport(request, { import_error: "Mindee OCR result is not completed/saved for this batch yet." });
  }

  try {
    const items = extractTransactions(typedBatch.mindee_statement_raw_json);
    if (items.length === 0) {
      await stageParserError(supabase, typedBatch, "Mindee OCR completed but no list_of_transactions field could be parsed. Raw JSON is saved for inspection.");
      return redirectToImport(request, { import_success: "Mindee parse ran but no transaction list was found; row-level parser error staged.", batch_id: importBatchId });
    }

    for (let index = 0; index < items.length; index += 1) {
      await stageRow(supabase, typedBatch, draftFromMindeeItem(items[index], typedBatch), index + 1, manualFxRate);
    }

    return redirectToImport(request, { import_success: `Parsed and staged ${items.length} Mindee transaction row(s). Review clean/errors/duplicates before commit.`, batch_id: importBatchId });
  } catch (error) {
    return redirectToImport(request, { import_error: error instanceof Error ? error.message : "Mindee statement parse failed." });
  }
}
