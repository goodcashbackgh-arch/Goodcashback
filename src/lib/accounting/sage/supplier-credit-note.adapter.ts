export type SagePurchaseCreditNoteLinePayload = {
  description: string;
  ledger_account_id: string;
  quantity: number;
  unit_price: number;
  tax_rate_id: string;
};

export type SagePurchaseCreditNotePayload = {
  purchase_credit_note: {
    contact_id: string;
    date: string;
    reference: string;
    credit_note_lines: SagePurchaseCreditNoteLinePayload[];
  };
};

export type SupplierCreditNoteSourceLine = {
  description: string;
  ledger_account_id: string;
  quantity: number;
  unit_price: number;
  tax_rate_id: string;
};

export type SupplierCreditNoteSource = {
  posting_intent: "supplier_credit_note";
  refund_evidence_submission_id: string;
  original_supplier_invoice_id: string;
  sage_retailer_supplier_contact_id: string;
  document_date: string;
  credit_note_ref: string;
  supplier_approval_status: string;
  supplier_control_status: string;
  gross_reconciled_to_document_yn: boolean;
  all_progressed_lines_coded_yn: boolean;
  refund_in_allocation_covers_approved_amount: boolean;
  frozen_payload_yn: boolean;
  already_posted_yn: boolean;
  lines: SupplierCreditNoteSourceLine[];
};

export type SupplierCreditNotePostResult = {
  sage_purchase_credit_note_id: string;
  sage_reference?: string;
  raw: unknown;
};

export type SagePoster = (path: string, body: unknown) => Promise<unknown>;

function assertNonEmpty(value: string, message: string) {
  if (!value || !value.trim()) throw new Error(message);
}

function assertPositiveNumber(value: number, message: string) {
  if (!Number.isFinite(value) || value <= 0) throw new Error(message);
}

export function validateSupplierCreditNoteSource(source: SupplierCreditNoteSource) {
  if (source.posting_intent !== "supplier_credit_note") throw new Error("Invalid posting intent for supplier credit note adapter.");
  if (source.supplier_approval_status !== "approved_current") throw new Error("Supplier refund evidence is not approved current.");
  if (source.supplier_control_status !== "approved_current") throw new Error("Supplier control status is not approved current.");
  if (!source.gross_reconciled_to_document_yn) throw new Error("Supplier credit note gross is not reconciled to the approved refund document.");
  if (!source.all_progressed_lines_coded_yn) throw new Error("Not all progressed supplier credit note lines are coded.");
  if (!source.refund_in_allocation_covers_approved_amount) throw new Error("Confirmed refund-IN allocation does not cover the accepted supplier credit amount.");
  if (!source.frozen_payload_yn) throw new Error("Supplier credit note payload is not frozen.");
  if (source.already_posted_yn) throw new Error("Supplier credit note has already been posted.");

  assertNonEmpty(source.refund_evidence_submission_id, "Missing refund evidence submission id.");
  assertNonEmpty(source.original_supplier_invoice_id, "Missing original supplier invoice id.");
  assertNonEmpty(source.sage_retailer_supplier_contact_id, "Missing Sage retailer/supplier contact id.");
  assertNonEmpty(source.document_date, "Missing supplier credit note document date.");
  assertNonEmpty(source.credit_note_ref, "Missing supplier credit note reference.");

  if (source.lines.length === 0) throw new Error("Supplier credit note has no lines.");

  for (const [index, line] of source.lines.entries()) {
    assertNonEmpty(line.description, `Missing description on supplier credit note line ${index + 1}.`);
    assertNonEmpty(line.ledger_account_id, `Missing Sage ledger account id on supplier credit note line ${index + 1}.`);
    assertNonEmpty(line.tax_rate_id, `Missing Sage tax rate id on supplier credit note line ${index + 1}.`);
    assertPositiveNumber(line.quantity, `Invalid quantity on supplier credit note line ${index + 1}.`);
    assertPositiveNumber(line.unit_price, `Invalid unit price on supplier credit note line ${index + 1}.`);
  }
}

export function buildSupplierCreditNotePayload(source: SupplierCreditNoteSource): SagePurchaseCreditNotePayload {
  validateSupplierCreditNoteSource(source);

  return {
    purchase_credit_note: {
      contact_id: source.sage_retailer_supplier_contact_id,
      date: source.document_date,
      reference: source.credit_note_ref,
      credit_note_lines: source.lines.map((line) => ({
        description: line.description,
        ledger_account_id: line.ledger_account_id,
        quantity: line.quantity,
        unit_price: line.unit_price,
        tax_rate_id: line.tax_rate_id,
      })),
    },
  };
}

function readSageObjectId(raw: unknown) {
  if (!raw || typeof raw !== "object") return "";
  const root = raw as Record<string, unknown>;
  const nested = root.purchase_credit_note;
  if (nested && typeof nested === "object") {
    const id = (nested as Record<string, unknown>).id;
    if (typeof id === "string" && id.trim()) return id;
  }
  const id = root.id;
  return typeof id === "string" ? id : "";
}

function readSageReference(raw: unknown) {
  if (!raw || typeof raw !== "object") return undefined;
  const root = raw as Record<string, unknown>;
  const nested = root.purchase_credit_note;
  if (nested && typeof nested === "object") {
    const reference = (nested as Record<string, unknown>).reference;
    if (typeof reference === "string" && reference.trim()) return reference;
  }
  const reference = root.reference;
  return typeof reference === "string" && reference.trim() ? reference : undefined;
}

export async function postSupplierCreditNoteToSage(source: SupplierCreditNoteSource, sagePost: SagePoster): Promise<SupplierCreditNotePostResult> {
  const payload = buildSupplierCreditNotePayload(source);
  const raw = await sagePost("/purchase_credit_notes", payload);
  const sage_purchase_credit_note_id = readSageObjectId(raw);

  if (!sage_purchase_credit_note_id) {
    throw new Error("Sage purchase credit note post did not return a confirmed object id.");
  }

  return {
    sage_purchase_credit_note_id,
    sage_reference: readSageReference(raw),
    raw,
  };
}
