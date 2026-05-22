export type SageContactAllocationArtefact = {
  artefact_id: string;
  amount: number;
};

export type SageContactAllocationPayload = {
  contact_allocation: {
    contact_id: string;
    allocated_artefacts: SageContactAllocationArtefact[];
    transaction_type_id: string;
  };
};

export type SupplierCreditAllocationSource = {
  posting_intent: "supplier_credit_allocation";
  original_supplier_invoice_id: string;
  original_supplier_invoice_sage_id: string;
  supplier_credit_note_sage_id: string;
  sage_retailer_supplier_contact_id: string;
  original_invoice_sage_contact_id: string;
  supplier_credit_note_sage_contact_id: string;
  allocation_amount_gbp: number;
  original_invoice_remaining_balance_gbp: number;
  supplier_credit_note_available_amount_gbp: number;
  supplier_credit_note_posted_yn: boolean;
  original_supplier_invoice_posted_yn: boolean;
  allocation_already_posted_yn: boolean;
  frozen_payload_yn: boolean;
  supplier_transaction_type_id: string;
};

export type SupplierCreditAllocationPostResult = {
  sage_allocation_id: string;
  raw: unknown;
};

export type SagePoster = (path: string, body: unknown) => Promise<unknown>;

function assertNonEmpty(value: string, message: string) {
  if (!value || !value.trim()) throw new Error(message);
}

function assertPositiveAmount(value: number, message: string) {
  if (!Number.isFinite(value) || value <= 0) throw new Error(message);
}

export function validateSupplierCreditAllocationSource(source: SupplierCreditAllocationSource) {
  if (source.posting_intent !== "supplier_credit_allocation") throw new Error("Invalid posting intent for supplier credit allocation adapter.");
  if (!source.supplier_credit_note_posted_yn) throw new Error("Supplier credit note is not posted to Sage.");
  if (!source.original_supplier_invoice_posted_yn) throw new Error("Original supplier invoice is not posted to Sage.");
  if (!source.frozen_payload_yn) throw new Error("Supplier credit allocation payload is not frozen.");
  if (source.allocation_already_posted_yn) throw new Error("Supplier credit allocation has already been posted.");

  assertNonEmpty(source.original_supplier_invoice_id, "Missing original supplier invoice id.");
  assertNonEmpty(source.original_supplier_invoice_sage_id, "Missing original supplier invoice Sage object id.");
  assertNonEmpty(source.supplier_credit_note_sage_id, "Missing supplier credit note Sage object id.");
  assertNonEmpty(source.sage_retailer_supplier_contact_id, "Missing Sage retailer/supplier contact id.");
  assertNonEmpty(source.original_invoice_sage_contact_id, "Missing original supplier invoice Sage contact id.");
  assertNonEmpty(source.supplier_credit_note_sage_contact_id, "Missing supplier credit note Sage contact id.");
  assertNonEmpty(source.supplier_transaction_type_id, "Missing Sage supplier allocation transaction type id. Resolve/validate this from Sage before posting; do not hardcode it.");

  if (source.original_invoice_sage_contact_id !== source.sage_retailer_supplier_contact_id) {
    throw new Error("Original supplier invoice Sage contact does not match the allocation contact.");
  }

  if (source.supplier_credit_note_sage_contact_id !== source.sage_retailer_supplier_contact_id) {
    throw new Error("Supplier credit note Sage contact does not match the allocation contact.");
  }

  assertPositiveAmount(source.allocation_amount_gbp, "Invalid supplier credit allocation amount.");
  assertPositiveAmount(source.original_invoice_remaining_balance_gbp, "Original supplier invoice remaining balance must be positive.");
  assertPositiveAmount(source.supplier_credit_note_available_amount_gbp, "Supplier credit note available amount must be positive.");

  if (source.allocation_amount_gbp > source.original_invoice_remaining_balance_gbp + 0.005) {
    throw new Error("Supplier credit allocation amount exceeds original supplier invoice remaining balance.");
  }

  if (source.allocation_amount_gbp > source.supplier_credit_note_available_amount_gbp + 0.005) {
    throw new Error("Supplier credit allocation amount exceeds available supplier credit note amount.");
  }
}

function round2(value: number) {
  return Math.round(value * 100) / 100;
}

export function buildSupplierCreditAllocationPayload(source: SupplierCreditAllocationSource): SageContactAllocationPayload {
  validateSupplierCreditAllocationSource(source);
  const amount = round2(source.allocation_amount_gbp);

  return {
    contact_allocation: {
      contact_id: source.sage_retailer_supplier_contact_id,
      allocated_artefacts: [
        {
          artefact_id: source.original_supplier_invoice_sage_id,
          amount,
        },
        {
          artefact_id: source.supplier_credit_note_sage_id,
          amount: -amount,
        },
      ],
      transaction_type_id: source.supplier_transaction_type_id,
    },
  };
}

function readSageObjectId(raw: unknown) {
  if (!raw || typeof raw !== "object") return "";
  const root = raw as Record<string, unknown>;
  const nested = root.contact_allocation;
  if (nested && typeof nested === "object") {
    const id = (nested as Record<string, unknown>).id;
    if (typeof id === "string" && id.trim()) return id;
  }
  const id = root.id;
  return typeof id === "string" ? id : "";
}

export async function postSupplierCreditAllocationToSage(source: SupplierCreditAllocationSource, sagePost: SagePoster): Promise<SupplierCreditAllocationPostResult> {
  const payload = buildSupplierCreditAllocationPayload(source);
  const raw = await sagePost("/contact_allocations", payload);
  const sage_allocation_id = readSageObjectId(raw);

  if (!sage_allocation_id) {
    throw new Error("Sage supplier credit allocation post did not return a confirmed allocation object id.");
  }

  return {
    sage_allocation_id,
    raw,
  };
}
