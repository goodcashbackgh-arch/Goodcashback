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
