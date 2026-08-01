"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const BUCKET = "invoice-evidence";
const AFFECTED = new Set(["damaged", "missing", "wrong", "held"]);

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function qty(formData: FormData, key: string) {
  const raw = text(formData, key);
  if (!raw) return 0;
  const value = Number(raw);
  return Number.isFinite(value) ? value : Number.NaN;
}

function destination(trackingId: string, type: "success" | "error", message: string) {
  return `/shipper/package-receipts/v2/${trackingId}?${type}=${encodeURIComponent(message)}`;
}

function safeName(name: string) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 120) || "evidence";
}

export async function recordExactPackageReceiptV2Action(formData: FormData) {
  const supabase = await createClient();
  const trackingId = text(formData, "tracking_submission_id");
  const submissionId = text(formData, "receipt_submission_id") || randomUUID();
  const predecessorId = text(formData, "correction_of_receipt_id") || null;
  const correctionReason = text(formData, "correction_reason") || null;

  if (!trackingId) redirect("/shipper/package-receipts?error=Missing%20tracking%20package%20reference.");

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("shipper_id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser?.shipper_id) redirect(destination(trackingId, "error", "Active shipper account not found."));

  const allocationIds = formData.getAll("allocation_id")
    .filter((value): value is string => typeof value === "string" && value.length > 0);
  if (!allocationIds.length) redirect(destination(trackingId, "error", "No exact package allocations were supplied."));

  const dispositions: Array<Record<string, unknown>> = [];
  let affectedTotal = 0;

  for (const allocationId of allocationIds) {
    const lineId = text(formData, `supplier_invoice_line_id_${allocationId}`);
    const allocated = qty(formData, `allocated_qty_${allocationId}`);
    const clean = qty(formData, `clean_qty_${allocationId}`);
    const affected = qty(formData, `affected_qty_${allocationId}`);
    const affectedType = text(formData, `affected_type_${allocationId}`);
    const note = text(formData, `condition_note_${allocationId}`);

    if (!lineId || !Number.isFinite(allocated) || allocated <= 0) {
      redirect(destination(trackingId, "error", "One or more allocation identities are invalid."));
    }
    if (!Number.isFinite(clean) || clean < 0 || !Number.isFinite(affected) || affected < 0) {
      redirect(destination(trackingId, "error", "Quantities must be valid non-negative numbers."));
    }
    if (Math.abs(clean + affected - allocated) > 0.0005) {
      redirect(destination(trackingId, "error", "Each line must balance exactly to its allocated quantity."));
    }

    if (clean > 0) dispositions.push({
      tracking_line_allocation_id: allocationId,
      supplier_invoice_line_id: lineId,
      disposition_type: "clean",
      quantity: clean,
      condition_note: null,
    });

    if (affected > 0) {
      if (!AFFECTED.has(affectedType)) {
        redirect(destination(trackingId, "error", "Choose a valid affected disposition."));
      }
      if (!note) redirect(destination(trackingId, "error", "Affected quantities require a factual note."));
      affectedTotal += affected;
      dispositions.push({
        tracking_line_allocation_id: allocationId,
        supplier_invoice_line_id: lineId,
        disposition_type: affectedType,
        quantity: affected,
        condition_note: note,
      });
    }
  }

  if (predecessorId && !correctionReason) {
    redirect(destination(trackingId, "error", "A correction reason is required."));
  }

  const files = formData.getAll("receipt_evidence_files")
    .filter((value): value is File => value instanceof File && value.size > 0);
  if (affectedTotal > 0 && files.length === 0) {
    redirect(destination(trackingId, "error", "Affected quantity requires at least one evidence file."));
  }

  const evidence: Array<Record<string, unknown>> = [];
  for (let index = 0; index < files.length; index += 1) {
    const file = files[index];
    const objectPath = `shipper-receipts/${shipperUser.shipper_id}/${trackingId}/${submissionId}/${index}-${safeName(file.name)}`;
    const { error: uploadError } = await supabase.storage.from(BUCKET).upload(objectPath, file, { upsert: false });
    if (uploadError) redirect(destination(trackingId, "error", `Evidence upload failed: ${uploadError.message}`));
    evidence.push({
      storage_object_path: objectPath,
      original_filename: file.name,
      content_type: file.type || null,
      display_order: index,
      tracking_line_allocation_id: null,
      disposition_type: null,
    });
  }

  const { data, error } = await (supabase as any).rpc("shipper_record_package_receipt_v2", {
    p_tracking_submission_id: trackingId,
    p_receipt_submission_id: submissionId,
    p_dispositions: dispositions,
    p_evidence: evidence,
    p_correction_of_receipt_id: predecessorId,
    p_correction_reason: correctionReason,
  });

  if (error) redirect(destination(trackingId, "error", error.message));

  revalidatePath("/shipper");
  revalidatePath("/shipper/package-receipts");
  revalidatePath(`/shipper/package-receipts/v2/${trackingId}`);
  revalidatePath(`/shipper/package-contents/${trackingId}`);

  redirect(destination(
    trackingId,
    "success",
    data?.idempotent_retry
      ? "Exact receipt already recorded; matching retry confirmed."
      : "Exact physical receipt recorded.",
  ));
}
