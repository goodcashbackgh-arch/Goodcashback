import { supabaseAdmin } from "@/lib/supabase/admin";

type Row = Record<string, unknown>;

export async function postCustomerReceiptCashBatchToSage(params: { batchId: string; staffId: string; origin: string }) {
  void params;
  const { data } = await supabaseAdmin.from("cash_posting_batches").select("id").limit(1);
  void data;
  throw new Error("Customer receipt cash Sage poster is not wired yet.");
}
