"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function saveImporterDeliveryProfileAction(formData: FormData) {
  const supabase = await createClient();
  const importerId = readString(formData, "importer_id");

  if (!importerId) redirect("/shipper/importer-delivery-profiles?error=Missing%20importer%20id.");

  const { error } = await (supabase as any).rpc("shipper_upsert_importer_export_delivery_profile_v1", {
    p_importer_id: importerId,
    p_final_recipient_name: readString(formData, "final_recipient_name") || null,
    p_final_recipient_address_line_1: readString(formData, "final_recipient_address_line_1") || null,
    p_final_recipient_address_line_2: readString(formData, "final_recipient_address_line_2") || null,
    p_final_recipient_city: readString(formData, "final_recipient_city") || null,
    p_final_recipient_region: readString(formData, "final_recipient_region") || null,
    p_final_recipient_country: readString(formData, "final_recipient_country") || null,
    p_final_recipient_phone: readString(formData, "final_recipient_phone") || null,
    p_final_recipient_email: readString(formData, "final_recipient_email") || null,
  });

  if (error) {
    redirect(`/shipper/importer-delivery-profiles?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper/importer-delivery-profiles");
  revalidatePath("/shipper/groupage-movements");
  redirect(`/shipper/importer-delivery-profiles?success=${encodeURIComponent("Importer export delivery profile saved")}`);
}
