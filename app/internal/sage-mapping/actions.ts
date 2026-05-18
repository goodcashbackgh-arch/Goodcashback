"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

export async function saveSageMappingAction(formData: FormData) {
  const mappingCode = String(formData.get("mapping_code") ?? "").trim();
  const sageExternalId = String(formData.get("sage_external_id") ?? "").trim();
  const sageDisplayName = String(formData.get("sage_display_name") ?? "").trim();
  const notes = String(formData.get("notes") ?? "").trim();

  if (!mappingCode) {
    redirect("/internal/sage-mapping?error=Missing mapping code");
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { error } = await (supabase as any).rpc("internal_upsert_sage_mapping_v1", {
    p_mapping_code: mappingCode,
    p_sage_external_id: sageExternalId,
    p_sage_display_name: sageDisplayName || null,
    p_notes: notes || null,
  });

  if (error) {
    redirect(`/internal/sage-mapping?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/internal/sage-mapping");
  revalidatePath("/internal/sage-ready");
  redirect("/internal/sage-mapping?success=Mapping saved");
}

export async function saveSagePartyMappingAction(formData: FormData) {
  const platformPartyType = String(formData.get("platform_party_type") ?? "").trim();
  const platformPartyId = String(formData.get("platform_party_id") ?? "").trim();
  const sageContactId = String(formData.get("sage_contact_id") ?? "").trim();
  const sageContactDisplayName = String(formData.get("sage_contact_display_name") ?? "").trim();
  const sageContactReference = String(formData.get("sage_contact_reference") ?? "").trim();
  const sageContactType = String(formData.get("sage_contact_type") ?? "unknown").trim() || "unknown";
  const notes = String(formData.get("notes") ?? "").trim();

  if (!platformPartyType || !platformPartyId) {
    redirect("/internal/sage-mapping?error=Missing platform party for Sage contact mapping");
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { error } = await (supabase as any).rpc("internal_upsert_sage_party_mapping_v1", {
    p_platform_party_type: platformPartyType,
    p_platform_party_id: platformPartyId,
    p_sage_contact_id: sageContactId,
    p_sage_contact_display_name: sageContactDisplayName || null,
    p_sage_contact_reference: sageContactReference || null,
    p_sage_contact_type: sageContactType,
    p_notes: notes || null,
  });

  if (error) {
    redirect(`/internal/sage-mapping?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/internal/sage-mapping");
  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");
  redirect("/internal/sage-mapping?success=Party mapping saved");
}
