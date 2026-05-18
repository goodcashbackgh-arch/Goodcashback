"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";
import { discoverSageCatalog } from "@/lib/sage/catalog";
import { parseCatalogItemValue, saveCatalogSnapshot } from "@/lib/accounting/catalog-cache";

async function requireStaffId() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff?.id) redirect("/auth/check");
  return { supabase, staffId: String(staff.id) };
}

function success(message: string) {
  revalidatePath("/internal/sage-mapping");
  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");
  redirect(`/internal/sage-mapping?success=${encodeURIComponent(message)}`);
}

function fail(message: string): never {
  redirect(`/internal/sage-mapping?error=${encodeURIComponent(message)}`);
}

export async function runReadOnlySageApiCheckAction() {
  const { staffId } = await requireStaffId();
  const discovery = await discoverSageCatalog();

  if (!discovery.ok) {
    fail(discovery.error || "Read-only Sage discovery failed.");
  }

  try {
    await saveCatalogSnapshot(staffId, discovery);
  } catch (error) {
    fail(error instanceof Error ? `Discovery succeeded but cache save failed: ${error.message}` : "Discovery succeeded but cache save failed.");
  }

  success("Read-only Sage API check saved. You can now map without rerunning it.");
}

export async function saveSageMappingAction(formData: FormData) {
  const mappingCode = String(formData.get("mapping_code") ?? "").trim();
  const sageExternalId = String(formData.get("sage_external_id") ?? "").trim();
  const sageDisplayName = String(formData.get("sage_display_name") ?? "").trim();
  const notes = String(formData.get("notes") ?? "").trim();

  if (!mappingCode) {
    redirect("/internal/sage-mapping?error=Missing mapping code");
  }

  const { supabase } = await requireStaffId();

  const { error } = await (supabase as any).rpc("internal_upsert_sage_mapping_v1", {
    p_mapping_code: mappingCode,
    p_sage_external_id: sageExternalId,
    p_sage_display_name: sageDisplayName || null,
    p_notes: notes || null,
  });

  if (error) {
    redirect(`/internal/sage-mapping?error=${encodeURIComponent(error.message)}`);
  }

  success("Mapping saved");
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

  const { supabase } = await requireStaffId();

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

  success("Party mapping saved");
}

export async function bulkSaveSageMappingsAction(formData: FormData) {
  const { supabase } = await requireStaffId();
  const mappingIndexes = formData.getAll("mapping_index").map((value) => String(value));
  let saved = 0;

  for (const index of mappingIndexes) {
    const mappingCode = String(formData.get(`mapping_code_${index}`) ?? "").trim();
    const picked = parseCatalogItemValue(formData.get(`mapping_pick_${index}`));
    if (!mappingCode || !picked?.id) continue;

    const { error } = await (supabase as any).rpc("internal_upsert_sage_mapping_v1", {
      p_mapping_code: mappingCode,
      p_sage_external_id: picked.id,
      p_sage_display_name: picked.display || null,
      p_notes: "Bulk saved from persisted read-only Sage discovery.",
    });

    if (error) fail(error.message);
    saved += 1;
  }

  success(saved === 1 ? "1 GL/tax/bank mapping saved" : `${saved} GL/tax/bank mappings saved`);
}

export async function bulkSaveSagePartyMappingsAction(formData: FormData) {
  const { supabase } = await requireStaffId();
  const partyIndexes = formData.getAll("party_index").map((value) => String(value));
  let saved = 0;

  for (const index of partyIndexes) {
    const platformPartyType = String(formData.get(`platform_party_type_${index}`) ?? "").trim();
    const platformPartyId = String(formData.get(`platform_party_id_${index}`) ?? "").trim();
    const contactType = String(formData.get(`sage_contact_type_${index}`) ?? "unknown").trim() || "unknown";
    const picked = parseCatalogItemValue(formData.get(`party_pick_${index}`));
    if (!platformPartyType || !platformPartyId || !picked?.id) continue;

    const { error } = await (supabase as any).rpc("internal_upsert_sage_party_mapping_v1", {
      p_platform_party_type: platformPartyType,
      p_platform_party_id: platformPartyId,
      p_sage_contact_id: picked.id,
      p_sage_contact_display_name: picked.display || null,
      p_sage_contact_reference: picked.reference || null,
      p_sage_contact_type: contactType,
      p_notes: "Bulk saved from persisted read-only Sage discovery.",
    });

    if (error) fail(error.message);
    saved += 1;
  }

  success(saved === 1 ? "1 party/contact mapping saved" : `${saved} party/contact mappings saved`);
}
