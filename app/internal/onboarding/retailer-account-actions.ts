"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function text(formData: FormData, key: string) {
  return String(formData.get(key) ?? "").trim();
}

function nullable(formData: FormData, key: string) {
  const value = text(formData, key);
  return value || null;
}

export async function upsertRetailerAccountAction(formData: FormData) {
  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("internal_upsert_retailer_account_v1", {
    p_retailer_account_id: nullable(formData, "retailer_account_id"),
    p_shipper_id: nullable(formData, "shipper_id"),
    p_retailer_id: nullable(formData, "retailer_id"),
    p_account_email: text(formData, "account_email"),
    p_account_username: nullable(formData, "account_username"),
    p_credentials_vault_ref: nullable(formData, "credentials_vault_ref"),
    p_credential_delivery_method: text(formData, "credential_delivery_method"),
    p_delivery_address_locked_to_hub_id: nullable(formData, "delivery_address_locked_to_hub_id"),
    p_card_last_4: nullable(formData, "card_last_4"),
    p_card_vault_ref: nullable(formData, "card_vault_ref"),
    p_status: text(formData, "status"),
  });

  if (error) throw new Error(error.message);
  revalidatePath("/internal/onboarding");
  redirect("/internal/onboarding?saved=Retailer%20account%20saved");
}
