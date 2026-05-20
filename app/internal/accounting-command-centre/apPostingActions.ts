"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import {
  postApPurchaseInvoiceBatchToSage,
  postSupplierGoodsApBatchToSage,
  postShipperApBatchToSage,
  type ApPostingLane,
} from "@/lib/sage/apPosting";
import { attachApSourcePdfToSage } from "@/lib/sage/apAttachment";

type StaffRow = {
  id: string;
  role_type: string | null;
  permissions_json: unknown;
};

type AttachmentSummary = {
  attempted: number;
  attached: number;
  failed: number;
  errors: string[];
};

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function formText(formData: FormData, key: string, fallback = "") {
  return String(formData.get(key) ?? fallback).trim();
}

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function appOrigin() {
  const configured = process.env.NEXT_PUBLIC_APP_URL?.trim()
    || process.env.NEXT_PUBLIC_SITE_URL?.trim()
    || process.env.SITE_URL?.trim();
  if (configured) return configured.replace(/\/$/, "");
  if (process.env.VERCEL_URL?.trim()) return `https://${process.env.VERCEL_URL.trim()}`;
  return "https://goodcashback-v2.vercel.app";
}

function apLaneFromForm(formData: FormData): ApPostingLane {
  const lane = formText(formData, "document_lane", "supplier_goods_ap");
  if (lane === "supplier_goods_ap" || lane === "shipper_ap") return lane;
  throw new Error(`Unsupported AP posting lane ${lane || "unknown"}`);
}

function apLaneLabel(lane: ApPostingLane) {
  return lane === "shipper_ap" ? "Shipper AP" : "Supplier goods AP";
}

async function requireAccountingPostingContext() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(staffError?.message || "Active staff account required")}`);
  }

  const row = staff as StaffRow;
  const canAccess = String(row.role_type ?? "") === "admin" || hasAccountingAdminTesting(row.permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre?error=Accounting admin access required");

  return { staffId: row.id };
}

async function postedApSnapshotIdsForBatch(batchId: string, lane: ApPostingLane) {
  const { data, error } = await supabaseAdmin
    .from("sage_posting_batch_rows")
    .select("snapshot_id")
    .eq("batch_id", batchId)
    .eq("document_lane", lane)
    .eq("posting_status", "posted");

  if (error) throw new Error(error.message);

  const rowSnapshotIds = Array.from(new Set(
    ((data ?? []) as Array<{ snapshot_id: string | null }>)
      .map((row) => text(row.snapshot_id))
      .filter(Boolean),
  ));

  if (rowSnapshotIds.length === 0) return [];

  const { data: snapshots, error: snapshotError } = await supabaseAdmin
    .from("sage_posting_snapshots")
    .select("id, sage_attachment_status")
    .in("id", rowSnapshotIds)
    .eq("document_lane", lane)
    .eq("sage_posting_status", "posted");

  if (snapshotError) throw new Error(snapshotError.message);

  return ((snapshots ?? []) as Array<{ id: string; sage_attachment_status: string | null }>)
    .filter((snapshot) => text(snapshot.sage_attachment_status) !== "attached")
    .map((snapshot) => snapshot.id);
}

async function attachPostedApSnapshots(args: { batchId: string; lane: ApPostingLane; staffId: string; origin: string }): Promise<AttachmentSummary> {
  const snapshotIds = await postedApSnapshotIdsForBatch(args.batchId, args.lane);
  const summary: AttachmentSummary = { attempted: snapshotIds.length, attached: 0, failed: 0, errors: [] };

  for (const snapshotId of snapshotIds) {
    try {
      const result = await attachApSourcePdfToSage({
        snapshotId,
        staffId: args.staffId,
        origin: args.origin,
      });
      summary.attached += result.attached;
    } catch (error) {
      summary.failed += 1;
      summary.errors.push(error instanceof Error ? error.message : `${apLaneLabel(args.lane)} source PDF attachment failed.`);
    }
  }

  return summary;
}

function apPostingSuccessMessage(result: { posted: number; failed: number; total: number; label?: string }, attachment?: AttachmentSummary) {
  const label = result.label || "AP purchase invoice";
  const base = `${label} Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.total} total.`;
  if (!attachment || result.posted === 0) return base;

  const attachmentText = ` Source PDF attachment: ${attachment.attached} attached, ${attachment.failed} failed, ${attachment.attempted} attempted.`;
  if (attachment.failed === 0) return `${base}${attachmentText}`;

  const firstError = attachment.errors[0] ? ` First attachment error: ${attachment.errors[0]}` : "";
  return `${base}${attachmentText}${firstError}`;
}

async function postApPurchaseInvoiceBatchAction(formData: FormData, forcedLane?: ApPostingLane) {
  const batchId = formText(formData, "batch_id", "");
  if (!batchId) redirect("/internal/accounting-command-centre?error=Missing posting batch id");

  const { staffId } = await requireAccountingPostingContext();
  let redirectTo = `/internal/accounting-command-centre/batches/${batchId}`;

  try {
    const origin = appOrigin();
    const lane = forcedLane ?? apLaneFromForm(formData);
    const result = await postApPurchaseInvoiceBatchToSage({
      batchId,
      staffId,
      origin,
      documentLane: lane,
    });

    let attachmentSummary: AttachmentSummary | undefined;
    if (result.posted > 0) {
      attachmentSummary = await attachPostedApSnapshots({ batchId, lane, staffId, origin });
    }

    if (result.failed > 0) {
      redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(`${result.label || "AP purchase invoice"} Sage posting finished with failures: ${result.posted} posted, ${result.failed} failed, ${result.total} total. Check the row Reason / error column.`)}`;
    } else if (attachmentSummary?.failed) {
      redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(apPostingSuccessMessage(result, attachmentSummary))}`;
    } else {
      redirectTo = `/internal/accounting-command-centre/batches/${batchId}?success=${encodeURIComponent(apPostingSuccessMessage(result, attachmentSummary))}`;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "AP purchase invoice Sage posting failed.";
    redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(message)}`;
  }

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}/supplier-goods-ap-attachments`);
  redirect(redirectTo);
}

export async function postApPurchaseInvoiceBatchToSageAction(formData: FormData) {
  return postApPurchaseInvoiceBatchAction(formData);
}

export async function postSupplierGoodsApBatchToSageAction(formData: FormData) {
  return postApPurchaseInvoiceBatchAction(formData, "supplier_goods_ap");
}

export async function postShipperApBatchToSageAction(formData: FormData) {
  return postApPurchaseInvoiceBatchAction(formData, "shipper_ap");
}

// Keep direct wrappers available for older drill-down routes/imports.
void postSupplierGoodsApBatchToSage;
void postShipperApBatchToSage;

export async function attachSupplierGoodsApSourcePdfAction(formData: FormData) {
  const batchId = formText(formData, "batch_id", "");
  const snapshotId = formText(formData, "snapshot_id", "");
  if (!batchId) redirect("/internal/accounting-command-centre?error=Missing posting batch id");
  if (!snapshotId) redirect(`/internal/accounting-command-centre/batches/${batchId}/supplier-goods-ap-attachments?error=${encodeURIComponent("Missing snapshot id")}`);

  const { staffId } = await requireAccountingPostingContext();
  let redirectTo = `/internal/accounting-command-centre/batches/${batchId}/supplier-goods-ap-attachments`;

  try {
    const result = await attachApSourcePdfToSage({
      snapshotId,
      staffId,
      origin: appOrigin(),
    });
    redirectTo = `/internal/accounting-command-centre/batches/${batchId}/supplier-goods-ap-attachments?success=${encodeURIComponent(`AP source PDF attached to Sage. Endpoint ${result.endpoint}; field ${result.fieldName}.`)}`;
  } catch (error) {
    const message = error instanceof Error ? error.message : "AP source PDF attachment failed.";
    redirectTo = `/internal/accounting-command-centre/batches/${batchId}/supplier-goods-ap-attachments?error=${encodeURIComponent(message)}`;
  }

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}/supplier-goods-ap-attachments`);
  redirect(redirectTo);
}
