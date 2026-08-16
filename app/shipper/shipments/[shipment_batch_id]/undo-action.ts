"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function undoShipmentBatchAction(formData: FormData) {
  const shipmentBatchId = readString(formData, "shipment_batch_id");
  const reason = readString(formData, "reason");

  if (!shipmentBatchId) {
    redirect("/shipper/shipments?error=Missing%20shipment%20batch%20id.");
  }

  if (!reason) {
    redirect(`/shipper/shipments/${shipmentBatchId}?error=${encodeURIComponent("Undo reason is required.")}`);
  }

  const supabase = await createClient();
  const { error } = await (supabase as any).rpc("shipper_undo_shipment_batch_v1", {
    p_shipment_batch_id: shipmentBatchId,
    p_reason: reason,
  });

  if (error) {
    redirect(`/shipper/shipments/${shipmentBatchId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath("/shipper/shipments/new");
  revalidatePath(`/shipper/shipments/${shipmentBatchId}`);

  redirect(`/shipper/shipments/${shipmentBatchId}?success=${encodeURIComponent("Shipment batch undone. Released packages will be selectable again only if they remain eligible.")}`);
}
