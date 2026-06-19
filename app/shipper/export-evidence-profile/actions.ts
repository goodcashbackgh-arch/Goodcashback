"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function saveExportEvidenceProfileAction(formData: FormData) {
  const supabase = await createClient();
  const profileId = readString(formData, "profile_id") || null;

  const { error } = await (supabase as any).rpc("shipper_upsert_export_evidence_profile_v1", {
    p_profile_id: profileId,
    p_profile_name: readString(formData, "profile_name") || "Default export evidence profile",
    p_exporter_name: readString(formData, "exporter_name") || null,
    p_exporter_address: readString(formData, "exporter_address") || null,
    p_exporter_vat_number: readString(formData, "exporter_vat_number") || null,
    p_default_movement_consignee_name: readString(formData, "default_movement_consignee_name") || null,
    p_default_movement_consignee_address: readString(formData, "default_movement_consignee_address") || null,
    p_default_notify_party_name: readString(formData, "default_notify_party_name") || null,
    p_default_notify_party_address: readString(formData, "default_notify_party_address") || null,
  });

  if (error) {
    redirect(`/shipper/export-evidence-profile?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper/export-evidence-profile");
  revalidatePath("/shipper/groupage-movements");
  redirect(`/shipper/export-evidence-profile?success=${encodeURIComponent("Export evidence profile saved")}`);
}
