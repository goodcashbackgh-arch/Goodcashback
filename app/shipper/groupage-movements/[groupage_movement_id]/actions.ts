"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

async function movementStatus(supabase: Awaited<ReturnType<typeof createClient>>, groupageMovementId: string) {
  const { data } = await supabase
    .from("shipper_groupage_movements")
    .select("groupage_movement_ref, status")
    .eq("id", groupageMovementId)
    .maybeSingle();

  return data as { groupage_movement_ref?: string | null; status?: string | null } | null;
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

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath("/shipper/groupage-movements");
  revalidatePath(`/shipper/groupage-movements/${groupageMovementId}`);
  redirect(`/shipper/groupage-movements/${groupageMovementId}?success=${encodeURIComponent("Groupage Movement refreshed from export profile and importer delivery profiles")}`);
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

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath("/shipper/groupage-movements");
  revalidatePath(`/shipper/groupage-movements/${groupageMovementId}`);

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

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath("/shipper/groupage-movements");
  revalidatePath(`/shipper/groupage-movements/${groupageMovementId}`);

  const ref = before?.groupage_movement_ref ?? groupageMovementId;
  redirect(`/shipper/groupage-movements?success=${encodeURIComponent(`Groupage Movement ${ref} cancelled and booking refs released.`)}`);
}
