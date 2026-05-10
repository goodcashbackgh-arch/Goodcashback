"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readOptionalNumber(formData: FormData, key: string) {
  const value = readString(formData, key);
  if (!value) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function readNullableDateTime(formData: FormData, key: string) {
  const value = readString(formData, key);
  return value || null;
}

export async function createShipmentBatchAction(formData: FormData) {
  const supabase = await createClient();
  const importerId = readString(formData, "importer_id");
  const bookingRef = readString(formData, "booking_ref");
  const shipmentCutoffAt = readString(formData, "shipment_cutoff_at") || null;
  const dispatchedAt = readString(formData, "dispatched_at") || null;
  const boxCount = readOptionalNumber(formData, "box_count");
  const notes = readString(formData, "notes") || null;
  const selected = formData.getAll("tracking_submission_ids").filter((value): value is string => typeof value === "string" && value.trim().length > 0);

  if (!importerId) redirect("/shipper/shipments/new?error=Choose%20an%20importer.");
  if (!bookingRef) redirect(`/shipper/shipments/new?importer=${encodeURIComponent(importerId)}&error=Booking%20reference%20is%20required.`);
  if (selected.length === 0) redirect(`/shipper/shipments/new?importer=${encodeURIComponent(importerId)}&error=Select%20at%20least%20one%20received-clean%20package.`);

  const { data, error } = await (supabase as any).rpc("shipper_create_shipment_batch_v1", {
    p_importer_id: importerId,
    p_tracking_submission_ids: selected,
    p_booking_ref: bookingRef,
    p_shipment_cutoff_at: shipmentCutoffAt,
    p_dispatched_at: dispatchedAt,
    p_box_count: boxCount,
    p_container_ref: null,
    p_bol_ref: null,
    p_notes: notes,
  });

  if (error) {
    redirect(`/shipper/shipments/new?importer=${encodeURIComponent(importerId)}&error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath("/shipper/shipments/new");
  redirect(`/shipper/shipments/${data}?success=${encodeURIComponent("Shipment batch created")}`);
}

export async function updateShipmentBatchHeaderAction(formData: FormData) {
  const supabase = await createClient();
  const shipmentBatchId = readString(formData, "shipment_batch_id");
  const bookingRef = readString(formData, "booking_ref");
  const shipmentCutoffAt = readNullableDateTime(formData, "shipment_cutoff_at");
  const dispatchedAt = readNullableDateTime(formData, "dispatched_at");
  const boxCount = readOptionalNumber(formData, "box_count");
  const notes = readString(formData, "notes") || null;

  if (!shipmentBatchId) redirect("/shipper/shipments?error=Missing%20shipment%20batch%20id.");
  if (!bookingRef) redirect(`/shipper/shipments/${shipmentBatchId}?error=Booking%20reference%20is%20required.`);

  const { error } = await (supabase as any).rpc("shipper_update_shipment_batch_header_v1", {
    p_shipment_batch_id: shipmentBatchId,
    p_booking_ref: bookingRef,
    p_shipment_cutoff_at: shipmentCutoffAt,
    p_dispatched_at: dispatchedAt,
    p_box_count: boxCount,
    p_notes: notes,
  });

  if (error) {
    redirect(`/shipper/shipments/${shipmentBatchId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath(`/shipper/shipments/${shipmentBatchId}`);
  redirect(`/shipper/shipments/${shipmentBatchId}?success=${encodeURIComponent("Shipment batch header updated")}`);
}
