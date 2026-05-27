"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const EVIDENCE_BUCKET = "invoice-evidence";

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

function readNullableDate(formData: FormData, key: string) {
  const value = readString(formData, key);
  return value || null;
}

function readBoolean(formData: FormData, key: string) {
  return formData.get(key) === "on" || formData.get(key) === "true";
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

async function uploadFinalExportEvidence(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  shipmentBatchId: string;
  documentKind: string;
  file: File;
}) {
  const objectPath = `shipper-final-export-evidence/${params.shipmentBatchId}/${params.documentKind}/${Date.now()}.${safeExt(params.file.name)}`;
  const { error } = await params.supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(objectPath, params.file, { upsert: false });

  if (error) {
    throw new Error(`Final export evidence upload failed. Ensure bucket '${EVIDENCE_BUCKET}' exists and is writable. ${error.message}`);
  }

  const { data } = params.supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
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

export async function saveExportEvidenceCompletionFieldsAction(formData: FormData) {
  const supabase = await createClient();
  const shipmentBatchId = readString(formData, "shipment_batch_id");

  if (!shipmentBatchId) redirect("/shipper/shipments?error=Missing%20shipment%20batch%20id.");

  const { error } = await (supabase as any).rpc("shipper_save_export_evidence_completion_fields_v1", {
    p_shipment_batch_id: shipmentBatchId,
    p_mbl_bol_sea_waybill_ref: readString(formData, "mbl_bol_sea_waybill_ref") || null,
    p_container_number: readString(formData, "container_number") || null,
    p_seal_number: readString(formData, "seal_number") || null,
    p_vessel_voyage: readString(formData, "vessel_voyage") || null,
    p_port_of_loading: readString(formData, "port_of_loading") || null,
    p_port_of_discharge: readString(formData, "port_of_discharge") || null,
    p_place_of_delivery: readString(formData, "place_of_delivery") || null,
    p_export_shipment_date: readNullableDate(formData, "export_shipment_date"),
    p_final_package_confirmation: readString(formData, "final_package_confirmation") || null,
    p_authorised_name: readString(formData, "authorised_name") || null,
    p_signature_stamp_confirmation_yn: readBoolean(formData, "signature_stamp_confirmation_yn"),
    p_notes: readString(formData, "export_evidence_notes") || null,
  });

  if (error) {
    redirect(`/shipper/shipments/${shipmentBatchId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath("/shipper/shipments");
  revalidatePath(`/shipper/shipments/${shipmentBatchId}`);
  revalidatePath(`/internal/export-evidence/draft/${shipmentBatchId}`);
  redirect(`/shipper/shipments/${shipmentBatchId}?success=${encodeURIComponent("Export evidence completion fields saved")}`);
}

export async function submitFinalExportEvidenceAction(formData: FormData) {
  const supabase = await createClient();
  const shipmentBatchId = readString(formData, "shipment_batch_id");
  const documentKind = readString(formData, "document_kind");
  const documentRef = readString(formData, "document_ref") || null;
  const notes = readString(formData, "notes") || null;
  const file = formData.get("final_export_evidence_file");

  if (!shipmentBatchId) redirect("/shipper/shipments?error=Missing%20shipment%20batch%20id.");
  if (!(file instanceof File) || file.size === 0) {
    redirect(`/shipper/shipments/${shipmentBatchId}/final-evidence?error=${encodeURIComponent("Upload the completed COS/final export evidence file.")}`);
  }

  let fileUrl: string;
  try {
    fileUrl = await uploadFinalExportEvidence({ supabase, shipmentBatchId, documentKind, file });
  } catch (error) {
    redirect(`/shipper/shipments/${shipmentBatchId}/final-evidence?error=${encodeURIComponent(error instanceof Error ? error.message : "Final export evidence upload failed")}`);
  }

  const { error } = await (supabase as any).rpc("shipper_submit_final_export_evidence_v1", {
    p_shipment_batch_id: shipmentBatchId,
    p_document_kind: documentKind,
    p_document_ref: documentRef,
    p_file_url: fileUrl,
    p_notes: notes,
  });

  if (error) {
    redirect(`/shipper/shipments/${shipmentBatchId}/final-evidence?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/shipper");
  revalidatePath(`/shipper/shipments/${shipmentBatchId}`);
  revalidatePath(`/shipper/shipments/${shipmentBatchId}/final-evidence`);
  revalidatePath(`/internal/export-evidence/draft/${shipmentBatchId}`);
  redirect(`/shipper/shipments/${shipmentBatchId}/final-evidence?success=${encodeURIComponent("Final export evidence uploaded for supervisor review")}`);
}
