"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readNullableString(formData: FormData, key: string) {
  const value = readString(formData, key);
  return value.length ? value : null;
}

function readNullableDate(formData: FormData, key: string) {
  const value = readString(formData, key);
  return /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : null;
}

async function movementStatus(supabase: Awaited<ReturnType<typeof createClient>>, groupageMovementId: string) {
  const { data } = await supabase
    .from("shipper_groupage_movements")
    .select("groupage_movement_ref, status")
    .eq("id", groupageMovementId)
    .maybeSingle();

  return data as { groupage_movement_ref?: string | null; status?: string | null } | null;
}

function revalidateGroupageMovement(groupageMovementId: string) {
  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath("/shipper/groupage-movements");
  revalidatePath(`/shipper/groupage-movements/${groupageMovementId}`);
}

export async function refreshGroupageMovementSnapshotsAction(formData: FormData) {
  const supabase = await createClient();
  const groupageMovementId = readString(formData, "groupage_movement_id");

  if (!groupageMovementId) redirect("/shipper/groupage-movements?error=Missing%20groupage%20movement%20id.");

  const { error } = await (supabase as any).rpc("shipper_refresh_groupage_movement_snapshots_v1", {
    p_groupage_movement_id: groupageMovementId,
  });

  if (error) {
    redirect(`/shipper/groupage-movements/${groupageMovementId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidateGroupageMovement(groupageMovementId);
  redirect(`/shipper/groupage-movements/${groupageMovementId}?success=${encodeURIComponent("Groupage Movement refreshed from export profile and importer delivery profiles")}`);
}

export async function saveGroupageMovementFactsAction(formData: FormData) {
  const supabase = await createClient();
  const groupageMovementId = readString(formData, "groupage_movement_id");

  if (!groupageMovementId) redirect("/shipper/groupage-movements?error=Missing%20groupage%20movement%20id.");

  const { error } = await (supabase as any).rpc("shipper_save_groupage_movement_facts_v1", {
    p_groupage_movement_id: groupageMovementId,
    p_mbl_bol_sea_waybill_ref: readNullableString(formData, "mbl_bol_sea_waybill_ref"),
    p_container_number: readNullableString(formData, "container_number"),
    p_seal_number: readNullableString(formData, "seal_number"),
    p_vessel_voyage: readNullableString(formData, "vessel_voyage"),
    p_port_of_loading: readNullableString(formData, "port_of_loading"),
    p_port_of_discharge: readNullableString(formData, "port_of_discharge"),
    p_place_of_delivery: readNullableString(formData, "place_of_delivery"),
    p_export_shipment_date: readNullableDate(formData, "export_shipment_date"),
    p_weight_text: readNullableString(formData, "weight_text"),
    p_movement_consignee_name: readNullableString(formData, "movement_consignee_name"),
    p_movement_consignee_address: readNullableString(formData, "movement_consignee_address"),
    p_notify_party_name: readNullableString(formData, "notify_party_name"),
    p_notify_party_address: readNullableString(formData, "notify_party_address"),
    p_authorised_name: readNullableString(formData, "authorised_name"),
    p_signature_stamp_confirmation_yn: formData.get("signature_stamp_confirmation_yn") === "on",
  });

  if (error) {
    redirect(`/shipper/groupage-movements/${groupageMovementId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidateGroupageMovement(groupageMovementId);
  redirect(`/shipper/groupage-movements/${groupageMovementId}?success=${encodeURIComponent("Movement transport facts saved")}`);
}

export async function excludeGroupageBatchesAction(formData: FormData) {
  const supabase = await createClient();
  const groupageMovementId = readString(formData, "groupage_movement_id");
  const selected = formData.getAll("exclude_shipment_batch_ids").filter((value): value is string => typeof value === "string" && value.trim().length > 0);

  if (!groupageMovementId) redirect("/shipper/groupage-movements?error=Missing%20groupage%20movement%20id.");
  if (selected.length === 0) redirect(`/shipper/groupage-movements/${groupageMovementId}?error=${encodeURIComponent("Select at least one booking reference to exclude.")}`);

  const { error } = await (supabase as any).rpc("shipper_exclude_groupage_batches_v1", {
    p_groupage_movement_id: groupageMovementId,
    p_shipment_batch_ids: selected,
  });

  if (error) {
    redirect(`/shipper/groupage-movements/${groupageMovementId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidateGroupageMovement(groupageMovementId);

  const status = await movementStatus(supabase, groupageMovementId);
  const ref = status?.groupage_movement_ref ?? groupageMovementId;
  if (status?.status === "voided") {
    redirect(`/shipper/groupage-movements?success=${encodeURIComponent(`Groupage Movement ${ref} cancelled/released because fewer than two booking refs remained.`)}`);
  }

  redirect(`/shipper/groupage-movements/${groupageMovementId}?success=${encodeURIComponent("Selected booking refs excluded")}`);
}

export async function cancelGroupageMovementAction(formData: FormData) {
  const supabase = await createClient();
  const groupageMovementId = readString(formData, "groupage_movement_id");
  const before = groupageMovementId ? await movementStatus(supabase, groupageMovementId) : null;

  if (!groupageMovementId) redirect("/shipper/groupage-movements?error=Missing%20groupage%20movement%20id.");

  const { error } = await (supabase as any).rpc("shipper_cancel_groupage_movement_v1", {
    p_groupage_movement_id: groupageMovementId,
  });

  if (error) {
    redirect(`/shipper/groupage-movements/${groupageMovementId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidateGroupageMovement(groupageMovementId);

  const ref = before?.groupage_movement_ref ?? groupageMovementId;
  redirect(`/shipper/groupage-movements?success=${encodeURIComponent(`Groupage Movement ${ref} cancelled and booking refs released.`)}`);
}
