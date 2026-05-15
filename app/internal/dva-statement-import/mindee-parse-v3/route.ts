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
  row_count: number | string | null;
  mindee_statement_ocr_status: string | null;
  mindee_statement_raw_json: unknown;
};

type FxRateRow = {
  rate_date: string;
  settlement_rate: number | string | null;
  settlement_card_markup_pct: number | string | null;
};

type Direction = "in" | "out" | null;

type DraftRow = {
  rawText: string;
  rawJson: Record<string, unknown>;
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
  errorCode: string | null;
  errorMessage: string | null;
};

type FxResolution = {
  source: "gbp_statement" | "exact_date" | "latest_prior" | "manual_base_rate_override" | "missing_fx_rate";
  requestedDate: string | null;
  appliedRateDate: string | null;
  baseFxRate: number | null;
  dailyMarkupPct: number;
  batchMarkupOverridePct: number;
  appliedMarkupPct: number;
  markupSource: "not_applicable" | "daily_fx_rate" | "batch_override" | "manual_override" | "none";
  warningNote: string | null;
};

const BALANCE_TOLERANCE = 0.02;

function redirectToImport(request: Request, params: Record<string, string>) {
  const url = new URL("/internal/dva-statement-import", new URL(request.url).origin);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return NextResponse.redirect(url, { status: 303 });
}

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function round2(value: number) {
  return Math.round(value * 100) / 100;
}

function numberValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return round2(value);
  if (typeof value === "string" && value.trim()) {
    const cleaned = value.replace(/£|GHS|GBP|,/gi, "");
    const parsed = Number(cleaned);
    if (Number.isFinite(parsed)) return round2(parsed);
    const match = cleaned.match(/-?\d+(?:\.\d{1,2})?/);
    if (match) {
      const n = Number(match[0]);
      return Number.isFinite(n) ? round2(n) : null;
    }
  }
  return null;
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

function extractFields(raw: unknown) {
  return getByPath(raw, ["inference", "result", "fields"])
    ?? getByPath(raw, ["document", "inference", "result", "fields"])
    ?? getByPath(raw, ["result", "fields"])
    ?? getByPath(raw, ["fields"]);
}

function headerField(raw: unknown, name: string) {
  const fields = getObject(extractFields(raw));
  if (!fields) return null;
  return valueFromObjectByName(fields, name);
}

function extractTransactions(raw: unknown) {
  const fields = extractFields(raw);
  const listField = getByPath(fields, ["list_of_transactions"])
    ?? getByPath(fields, ["transactions"])
    ?? getByPath(fields, ["transaction_lines"]);
  return asArray(listField);
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
  const isInboundFundingText = lower.includes("transfer from") || lower.includes("from ") || lower.includes("pmt") || lower.includes("payment") || lower.includes("shopping") || lower.includes("deposit") || lower.includes("ib oc");
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

function extractCardLast4(description: string) {
  const masked = description.match(/(?:\*{4,}|x{4,}|X{4,})(\d{4})\b/);
  if (masked) return masked[1];
  const visaLike = description.match(/\b\d{6}\*{4,}(\d{4})\b/);
  return visaLike?.[1] ?? null;
}

function resolveDirectionAndAmount(args: {
  explicitDirection: Direction;
  debitAmount: number | null;
  creditAmount: number | null;
  genericAmount: number | null;
  previousBalance: number | null;
  balanceAfter: number | null;
}) {
  const explicitAmount = args.creditAmount !== null && args.creditAmount > 0
    ? Math.abs(args.creditAmount)
    : args.debitAmount !== null && args.debitAmount > 0
      ? Math.abs(args.debitAmount)
      : args.genericAmount !== null && args.genericAmount !== 0
        ? Math.abs(args.genericAmount)
        : null;

  let direction = args.explicitDirection;
  let amount = explicitAmount;
  let balanceDirection: Direction = null;
  let balanceAmount: number | null = null;
  let correction: string | null = null;
  let balanceDelta: number | null = null;

  if (args.previousBalance !== null && args.balanceAfter !== null) {
    balanceDelta = round2(args.balanceAfter - args.previousBalance);
    if (Math.abs(balanceDelta) > BALANCE_TOLERANCE) {
      balanceDirection = balanceDelta > 0 ? "in" : "out";
      balanceAmount = Math.abs(balanceDelta);
      const amountMatches = amount === null || Math.abs(Math.abs(amount) - balanceAmount) <= BALANCE_TOLERANCE;

      if (amountMatches) {
        if (direction && direction !== balanceDirection) {
          correction = `Mindee direction ${direction} corrected to ${balanceDirection} using balance-after movement.`;
        }
        direction = balanceDirection;
        amount = balanceAmount;
      }
    }
  }

  if (!direction && args.genericAmount !== null && args.genericAmount !== 0) {
    direction = args.genericAmount < 0 ? "out" : "in";
    amount = Math.abs(args.genericAmount);
  }

  return {
    direction,
    amount: amount === null ? null : round2(Math.abs(amount)),
    balanceDirection,
    balanceAmount,
    balanceDelta,
    correction,
  };
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

function draftFromMindeeItem(item: unknown, batch: Batch, headerStatementDate: string | null, previousBalance: number | null): DraftRow {
  const description = cleanText(fieldFromItemAny(item, ["description", "details", "label", "transaction_description"]));
  const postingDate = parseDate(fieldFromItemAny(item, ["date", "posting_date", "book_date"]));
  const valueDate = parseDate(fieldFromItemAny(item, ["value_date", "transaction_date", "processed_date"]));
  const debitAmount = numberValue(fieldFromItemAny(item, ["debit_amount", "debit", "withdrawal", "paid_out"]));
  const creditAmount = numberValue(fieldFromItemAny(item, ["credit_amount", "credit", "deposit", "paid_in"]));
  const genericAmount = numberValue(fieldFromItemAny(item, ["amount", "transaction_amount", "value"]));
  const explicitDirection = normaliseMindeeDirection(fieldFromItemAny(item, ["direction", "type", "transaction_direction"]));
  const balanceAfter = numberValue(fieldFromItemAny(item, ["balance_after", "running_balance", "balance"]));
  const reference = cleanText(fieldFromItemAny(item, ["reference", "bank_reference", "transaction_reference"])) || extractReference(description);
  const resolved = resolveDirectionAndAmount({ explicitDirection, debitAmount, creditAmount, genericAmount, previousBalance, balanceAfter });
  const classified = classify(description, resolved.direction);
  const merchantRaw = merchantFromDescription(description);
  const rawObj = getObject(item) ?? {};

  let errorCode: string | null = null;
  let errorMessage: string | null = null;
  if (!postingDate && !valueDate) {
    errorCode = "missing_transaction_date";
    errorMessage = "Mindee row did not include a usable transaction date.";
  } else if (!resolved.direction) {
    errorCode = "missing_direction";
    errorMessage = "Could not determine debit/credit direction from Mindee fields or balance movement.";
  } else if (resolved.amount === null) {
    errorCode = "missing_amount";
    errorMessage = "Could not determine transaction amount from Mindee fields or balance movement.";
  }

  return {
    rawText: description || JSON.stringify(item).slice(0, 1000),
    rawJson: {
      ...rawObj,
      _goodcashback_balance_check: {
        previous_balance: previousBalance,
        balance_after: balanceAfter,
        balance_delta: resolved.balanceDelta,
        balance_direction: resolved.balanceDirection,
        balance_amount: resolved.balanceAmount,
        mindee_direction: explicitDirection,
        mindee_debit_amount: debitAmount,
        mindee_credit_amount: creditAmount,
        mindee_generic_amount: genericAmount,
        corrected: Boolean(resolved.correction),
        correction_note: resolved.correction,
      },
    },
    statementDate: headerStatementDate ?? postingDate,
    transactionDate: valueDate ?? postingDate,
    direction: classified.direction,
    transactionType: classified.type,
    amountLocal: resolved.amount,
    balanceAfter,
    cardLast4: extractCardLast4(description),
    merchantRaw,
    merchantNormalised: normaliseMerchant(merchantRaw),
    bankReference: reference,
    authOrSettlementRef: extractReference(description),
    transactionFamilyRef: reference,
    confidence: resolved.balanceDirection ? "high" : explicitDirection ? "medium" : "low",
    errorCode,
    errorMessage,
  };
}

function toPositiveNumber(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function findFxRateForDate(rates: FxRateRow[], requestedDate: string | null) {
  if (!requestedDate) return null;
  const exact = rates.find((rate) => rate.rate_date === requestedDate && toPositiveNumber(rate.settlement_rate));
  if (exact) return { rate: exact, source: "exact_date" as const };
  const prior = rates.find((rate) => rate.rate_date <= requestedDate && toPositiveNumber(rate.settlement_rate));
  return prior ? { rate: prior, source: "latest_prior" as const } : null;
}

function resolveFxForRow(row: DraftRow, localCcy: string, manualFxRate: number | null, batchMarkupOverridePct: number, fxRates: FxRateRow[]): FxResolution {
  const requestedDate = row.transactionDate || row.statementDate;

  if (localCcy === "GBP") {
    return {
      source: "gbp_statement",
      requestedDate,
      appliedRateDate: null,
      baseFxRate: 1,
      dailyMarkupPct: 0,
      batchMarkupOverridePct: 0,
      appliedMarkupPct: 0,
      markupSource: "not_applicable",
      warningNote: null,
    };
  }

  const matched = findFxRateForDate(fxRates, requestedDate);
  const matchedRate = matched ? toPositiveNumber(matched.rate.settlement_rate) : null;
  const dailyMarkupPct = matched ? Number(matched.rate.settlement_card_markup_pct ?? 0) : 0;
  const baseFxRate = matchedRate ?? manualFxRate;
  const appliedMarkupPct = batchMarkupOverridePct > 0 ? batchMarkupOverridePct : dailyMarkupPct;
  const markupSource = batchMarkupOverridePct > 0
    ? "batch_override"
    : matchedRate
      ? "daily_fx_rate"
      : manualFxRate
        ? "manual_override"
        : "none";
  const source = matched?.source ?? (manualFxRate ? "manual_base_rate_override" : "missing_fx_rate");
  const warningNote = source === "latest_prior"
    ? `FX warning: used latest prior settlement/base rate from ${matched?.rate.rate_date} for transaction date ${requestedDate}.`
    : source === "manual_base_rate_override"
      ? "FX warning: used manual base FX rate because no exact or prior daily settlement/base rate was found."
      : null;

  return {
    source,
    requestedDate,
    appliedRateDate: matched?.rate.rate_date ?? null,
    baseFxRate,
    dailyMarkupPct,
    batchMarkupOverridePct,
    appliedMarkupPct,
    markupSource,
    warningNote,
  };
}

function addFxResidualAudit(row: DraftRow, fx: FxResolution) {
  const amount = row.amountLocal;
  const statementTotalGbp = amount !== null && fx.baseFxRate ? round2(amount / fx.baseFxRate) : null;

  const supplierEquivalentMultiplier = Math.max(0, 1 - fx.appliedMarkupPct / 100);

  const supplierEquivalentRate =
    fx.baseFxRate && supplierEquivalentMultiplier > 0
      ? fx.baseFxRate / supplierEquivalentMultiplier
      : null;

  const supplierEquivalentGbp =
    statementTotalGbp !== null
      ? round2(statementTotalGbp * supplierEquivalentMultiplier)
      : null;

  const fxCardMarkupResidualGbp =
    statementTotalGbp !== null && supplierEquivalentGbp !== null
      ? round2(statementTotalGbp - supplierEquivalentGbp)
      : null;
  const existingBalanceCheck = getObject(row.rawJson._goodcashback_balance_check) ?? {};

  return {
    ...row.rawJson,
    _goodcashback_balance_check: {
      ...existingBalanceCheck,
      correction_note: [cleanText(existingBalanceCheck.correction_note), fx.warningNote].filter(Boolean).join(" ") || null,
    },
    _goodcashback_fx_lookup: {
      source: fx.source,
      requested_date: fx.requestedDate,
      applied_rate_date: fx.appliedRateDate,
      base_statement_rate: fx.baseFxRate,
      daily_settlement_markup_pct: fx.dailyMarkupPct,
      batch_markup_override_pct: fx.batchMarkupOverridePct > 0 ? fx.batchMarkupOverridePct : null,
      settlement_markup_pct: fx.appliedMarkupPct,
      settlement_markup_source: fx.markupSource,
      statement_total_gbp: statementTotalGbp,
      supplier_equivalent_rate: supplierEquivalentRate,
      supplier_equivalent_gbp: supplierEquivalentGbp,
      fx_card_markup_residual_gbp: fxCardMarkupResidualGbp,
      supplier_equivalent_multiplier: supplierEquivalentMultiplier,
      interpretation: interpretation: "amount_gbp_equivalent is the full statement GBP total using the base settlement rate. Settlement markup is treated as a percentage of the statement GBP value: supplier_equivalent_gbp = statement_total_gbp * (1 - markup_pct / 100). A positive batch settlement markup override replaces daily markups for all rows in the batch.",
    },
  };
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const importBatchId = cleanText(formData.get("import_batch_id"));
  if (!importBatchId) return redirectToImport(request, { import_error: "Missing import batch id for Mindee parse." });

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectToImport(request, { import_error: "Please sign in again before parsing statement OCR." });

  const { data: batchData, error: batchError } = await supabase
    .from("dva_statement_import_batches")
    .select("id, importer_id, source_bank, statement_period_from, statement_period_to, local_ccy, default_card_markup_pct, status, row_count, mindee_statement_ocr_status, mindee_statement_raw_json")
    .eq("id", importBatchId)
    .maybeSingle();

  if (batchError || !batchData) return redirectToImport(request, { import_error: batchError?.message ?? "Statement import batch not found." });
  const batch = batchData as Batch;

  if (Number(batch.row_count ?? 0) > 0) {
    return redirectToImport(request, { import_error: "This batch already has staged rows. Reset or void the batch before parsing again.", batch_id: importBatchId });
  }

  if (batch.mindee_statement_ocr_status !== "completed") {
    return redirectToImport(request, { import_error: `Mindee OCR is not completed for this batch. Current status: ${batch.mindee_statement_ocr_status ?? "not_started"}.`, batch_id: importBatchId });
  }

  if (!batch.mindee_statement_raw_json) {
    return redirectToImport(request, { import_error: "No saved Mindee raw JSON found for this batch.", batch_id: importBatchId });
  }

  const localCcy = cleanText(batch.local_ccy).toUpperCase() || "GBP";
  const manualFxRaw = cleanText(formData.get("manual_fx_rate"));
  const manualFxRate = manualFxRaw ? Number(manualFxRaw) : localCcy === "GBP" ? 1 : null;
  if (manualFxRaw && (!manualFxRate || !Number.isFinite(manualFxRate) || manualFxRate <= 0)) {
    return redirectToImport(request, { import_error: "Manual base FX override must be greater than zero when supplied.", batch_id: importBatchId });
  }

  const batchMarkupOverridePct = Number(batch.default_card_markup_pct ?? 0);
  const transactions = extractTransactions(batch.mindee_statement_raw_json);
  if (transactions.length === 0) {
    return redirectToImport(request, { import_error: "Mindee raw JSON did not contain list_of_transactions items.", batch_id: importBatchId });
  }

  const statementDate = parseDate(headerField(batch.mindee_statement_raw_json, "statement_date"))
    ?? parseDate(headerField(batch.mindee_statement_raw_json, "statement_period_end_date"))
    ?? batch.statement_period_to;
  let previousBalance = numberValue(headerField(batch.mindee_statement_raw_json, "beginning_balance"));
  const draftedRows: DraftRow[] = [];

  for (const transaction of transactions) {
    const row = draftFromMindeeItem(transaction, batch, statementDate, previousBalance);
    draftedRows.push(row);
    if (row.balanceAfter !== null) previousBalance = row.balanceAfter;
  }

  let fxRates: FxRateRow[] = [];
  if (localCcy !== "GBP") {
    const requestedDates = draftedRows
      .map((row) => row.transactionDate || row.statementDate)
      .filter((value): value is string => Boolean(value));
    const maxRequestedDate = requestedDates.sort().at(-1) ?? batch.statement_period_to;
    const { data: importer, error: importerError } = await supabase
      .from("importers")
      .select("country_id")
      .eq("id", batch.importer_id)
      .maybeSingle();

    if (importerError) return redirectToImport(request, { import_error: importerError.message, batch_id: importBatchId });

    const countryId = cleanText(importer?.country_id);
    if (countryId) {
      const { data: rateRows, error: rateError } = await supabase
        .from("fx_rates")
        .select("rate_date, settlement_rate, settlement_card_markup_pct")
        .eq("country_id", countryId)
        .lte("rate_date", maxRequestedDate)
        .order("rate_date", { ascending: false })
        .limit(500);

      if (rateError) return redirectToImport(request, { import_error: rateError.message, batch_id: importBatchId });
      fxRates = (rateRows ?? []) as FxRateRow[];
    }
  }

  let staged = 0;
  let errors = 0;
  for (let i = 0; i < draftedRows.length; i += 1) {
    const row = draftedRows[i];
    const fx = resolveFxForRow(row, localCcy, manualFxRate, batchMarkupOverridePct, fxRates);
    const amountGbp = row.amountLocal !== null && fx.baseFxRate ? round2(row.amountLocal / fx.baseFxRate) : null;
    const fxErrorCode = amountGbp === null ? "missing_fx_rate" : null;
    const fxErrorMessage = amountGbp === null
      ? "GBP equivalent could not be calculated. Add a daily settlement/base FX rate for this transaction date or provide a manual base FX override."
      : null;
    const auditedRawJson = addFxResidualAudit(row, fx);
    const rowHash = fingerprint(batch, row);
    const errorCode = row.errorCode ?? fxErrorCode;
    const errorMessage = row.errorMessage ?? fxErrorMessage;

    const { error: stageError } = await supabase.rpc("staff_stage_dva_statement_import_row", {
      p_import_batch_id: importBatchId,
      p_source_row_number: i + 1,
      p_source_page_number: null,
      p_raw_text: row.rawText,
      p_raw_json: auditedRawJson,
      p_statement_date: row.statementDate,
      p_transaction_date: row.transactionDate,
      p_direction: row.direction,
      p_transaction_type_candidate: row.transactionType,
      p_amount_local_ccy: row.amountLocal,
      p_balance_after_local_ccy: row.balanceAfter,
      p_local_ccy: localCcy,
      p_fx_rate_applied: fx.baseFxRate,
      p_card_markup_pct_applied: fx.appliedMarkupPct,
      p_amount_gbp_equivalent: amountGbp,
      p_card_last4: row.cardLast4,
      p_merchant_raw: row.merchantRaw,
      p_merchant_normalised: row.merchantNormalised,
      p_bank_reference: row.bankReference,
      p_auth_or_settlement_ref: row.authOrSettlementRef,
      p_transaction_family_ref: row.transactionFamilyRef,
      p_parser_confidence: row.confidence,
      p_error_code: errorCode,
      p_error_message: errorMessage,
      p_statement_line_fingerprint_hash: rowHash,
    });

    if (stageError) return redirectToImport(request, { import_error: stageError.message, batch_id: importBatchId });
    if (errorCode) errors += 1;
    staged += 1;
  }

  return redirectToImport(request, {
    import_success: `Balance-aware Mindee parser staged ${staged} row(s) with ${errors} parser error(s). Review staged rows before commit.`,
    batch_id: importBatchId,
  });
}
