"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

export async function approveShippingApportionmentAction(formData: FormData) {
  const supabase = await createClient();
  const shippingDocumentId = readString(formData, "shipping_document_id");
  const approvalNote = readString(formData, "approval_note") || null;
  const trackingIds = formData.getAll("tracking_submission_id").map(String);
  const lineIds = formData.getAll("supplier_invoice_line_id").map(String);
  const categoryCodes = formData.getAll("category_code").map(String);
  const overrideReasons = formData.getAll("override_reason").map(String);

  if (!shippingDocumentId) {
    redirect("/internal/shipping-control/shipper-documents?error=Missing%20shipping%20document.");
  }

  const overrides = lineIds.map((lineId, index) => ({
    supplier_invoice_line_id: lineId,
    tracking_submission_id: trackingIds[index],
    category_code: categoryCodes[index],
    override_reason: overrideReasons[index]?.trim() || null,
  })).filter((row) => row.supplier_invoice_line_id && row.tracking_submission_id && row.category_code);

  const { error } = await (supabase as any).rpc("internal_approve_shipping_apportionment_v1", {
    p_shipping_document_id: shippingDocumentId,
    p_category_overrides: overrides,
    p_approval_note: approvalNote,
  });

  if (error) {
    redirect(`/internal/shipping-control/apportionment/${shippingDocumentId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/internal/shipping-control");
  revalidatePath("/internal/shipping-control/shipper-documents");
  revalidatePath(`/internal/shipping-control/apportionment/${shippingDocumentId}`);
  redirect(`/internal/shipping-control/apportionment/${shippingDocumentId}?success=${encodeURIComponent("Shipping cost apportionment approved")}`);
}
