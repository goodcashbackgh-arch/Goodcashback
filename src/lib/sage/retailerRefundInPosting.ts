import crypto from "node:crypto";

type Row = Record<string, any>;

export type RetailerRefundInRow = {
  id: string;
  batch_id: string;
  snapshot_id: string;
  source_id: string;
  posting_category: string;
  idempotency_key: string | null;
  amount_gbp: string | number | null;
  validation_status: string;
  posting_status: string;
  request_payload: Row;
  response_payload: Row | null;
  sage_object_id: string | null;
  attempt_count: number | null;
};

export type RetailerRefundInPayload = {
  contact_payment: {
    transaction_type_id: "VENDOR_REFUND";
    contact_id: string;
    bank_account_id: string;
    date: string;
    total_amount: number;
    reference: string;
    allocated_artefacts: Array<{
      artefact_id: string;
      amount: number;
    }>;
  };
};

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
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

function getPath(value: unknown, path: Array<string | number>) {
  let current = value;
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

export function retailerRefundInPayloadHash(value: unknown) {
  return crypto.createHash("sha256").update(JSON.stringify(value ?? {})).digest("hex");
}

export function buildRetailerRefundInCandidatePayload(row: RetailerRefundInRow): RetailerRefundInPayload {
  if (row.posting_category !== "retailer_refund_received") {
    throw new Error("Retailer refund IN adapter only supports retailer_refund_received rows.");
  }
  if (row.validation_status !== "validated") {
    throw new Error("Retailer refund IN row must be validated before posting.");
  }
  if (!["blocked_endpoint_prove_required", "not_posted", "failed_retryable"].includes(row.posting_status)) {
    throw new Error(`Retailer refund IN row status ${row.posting_status} is not eligible for endpoint proof.`);
  }

  const payload = asObject(row.request_payload);
  const refs = asObject(payload.internal_reference_json);
  const refundCandidate = asObject(payload.supplier_refund_candidate);
  const bankToGl = asObject(payload.bank_to_gl);
  const contactId = firstText(payload, [
    ["supplier_refund_candidate", "contact_id"],
    ["contact_payment", "contact_id"],
    ["supplier_target", "sage_contact_id"],
    ["internal_reference_json", "target_sage_contact_id"],
  ]) || text(refundCandidate.contact_id);
  const bankAccountId = firstText(payload, [
    ["supplier_refund_candidate", "bank_account_id"],
    ["contact_payment", "bank_account_id"],
    ["internal_reference_json", "target_sage_bank_account_id"],
    ["bank_to_gl", "bank_account_id"],
  ]) || text(bankToGl.bank_account_id);
  const date = firstText(payload, [
    ["supplier_refund_candidate", "date"],
    ["contact_payment", "date"],
    ["bank_to_gl", "date"],
  ]);
  const reference = firstText(payload, [
    ["supplier_refund_candidate", "reference"],
    ["contact_payment", "reference"],
    ["bank_to_gl", "reference"],
  ]);
  const amount = num(getPath(payload, ["supplier_refund_candidate", "total_amount"]))
    || num(getPath(payload, ["contact_payment", "total_amount"]))
    || num(getPath(payload, ["bank_to_gl", "total_amount"]))
    || num(row.amount_gbp);
  const purchaseCreditNoteId = firstText(payload, [
    ["allocation_target", "purchase_credit_note_id"],
    ["supplier_refund_candidate", "purchase_credit_note_id"],
    ["internal_reference_json", "target_sage_object_id"],
    ["internal_reference_json", "supplier_credit_note_sage_id"],
  ]) || text(refs.target_sage_object_id) || text(refs.supplier_credit_note_sage_id);

  if (!contactId) throw new Error("Retailer refund IN payload missing retailer/supplier Sage contact_id.");
  if (!bankAccountId) throw new Error("Retailer refund IN payload missing Sage bank_account_id.");
  if (!date) throw new Error("Retailer refund IN payload missing posting date.");
  if (!reference) throw new Error("Retailer refund IN payload missing reference.");
  if (!(amount > 0)) throw new Error("Retailer refund IN amount must be positive.");
  if (Math.abs(amount - num(row.amount_gbp)) > 0.01) throw new Error("Retailer refund IN payload amount does not match frozen batch row amount.");
  if (!purchaseCreditNoteId) throw new Error("Retailer refund IN needs the posted Sage purchase credit note id before live posting can be proven.");

  return {
    contact_payment: {
      transaction_type_id: "VENDOR_REFUND",
      contact_id: contactId,
      bank_account_id: bankAccountId,
      date,
      total_amount: amount,
      reference,
      allocated_artefacts: [{ artefact_id: purchaseCreditNoteId, amount }],
    },
  };
}

export function retailerRefundInEndpointProofRequiredMessage() {
  return "Retailer refund IN is a hybrid cash/supplier-credit posting: use IN bank receipt controls plus retailer_supplier contact and posted purchase credit note allocation. Do not enable live posting until VENDOR_REFUND / allocated_artefacts is proven against Sage.";
}
