import "server-only";

import { supabaseAdmin } from "@/lib/supabase/admin";
import { postBankFeeCashBatchToSage } from "@/lib/sage/bankFeePosting";

type BankGlPostParams = {
  batchId: string;
  staffId: string;
  origin: string;
};

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

async function requireBankFeeTaxRateId() {
  const { data, error } = await supabaseAdmin
    .from("sage_mapping_settings")
    .select("sage_external_id")
    .eq("mapping_code", "BANK_FEE_TAX_RATE")
    .eq("is_active", true)
    .maybeSingle();

  if (error) throw new Error(error.message);

  const taxRateId = text(data?.sage_external_id);
  if (!taxRateId) {
    throw new Error("BANK_FEE_TAX_RATE Sage mapping is missing. Map it to Sage Exempt 0.00% before posting bank/provider/card fees.");
  }

  return taxRateId;
}

export async function postBankGlControlCashBatchToSage(params: BankGlPostParams) {
  const taxRateId = await requireBankFeeTaxRateId();
  const previous = process.env.SAGE_BANK_FEE_TAX_RATE_ID;

  process.env.SAGE_BANK_FEE_TAX_RATE_ID = taxRateId;

  try {
    return await postBankFeeCashBatchToSage(params);
  } finally {
    if (previous === undefined) {
      delete process.env.SAGE_BANK_FEE_TAX_RATE_ID;
    } else {
      process.env.SAGE_BANK_FEE_TAX_RATE_ID = previous;
    }
  }
}
