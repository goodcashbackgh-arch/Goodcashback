"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readNullableNumber(formData: FormData, key: string) {
  const value = readString(formData, key);
  if (!value) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export async function reviewShippingDocumentAction(formData: FormData) {
  const supabase = await createClient();
  const shippingDocumentId = readString(formData, "shipping_document_id");
  const decision = readString(formData, "decision");
  const reviewNote = readString(formData, "review_note") || null;
  const extractedDocumentRef = readString(formData, "extracted_document_ref") || null;
  const extractedDocumentDate = readString(formData, "extracted_document_date") || null;
  const extractedCurrencyCode = readString(formData, "extracted_currency_code") || null;
  const extractedTotalAmount = readNullableNumber(formData, "extracted_total_amount");

  if (!shippingDocumentId) {
    redirect("/internal/shipping-control/shipper-documents?error=Missing%20shipping%20document.");
  }

  if (!["mark_ocr_queued", "mark_ocr_not_applicable", "accept_current", "reject_resubmit_required"].includes(decision)) {
    redirect(`/internal/shipping-control/shipper-documents/${shippingDocumentId}?error=Choose%20a%20valid%20review%20decision.`);
  }

  const { error } = await (supabase as any).rpc("internal_review_shipping_document_v1", {
    p_shipping_document_id: shippingDocumentId,
    p_decision: decision,
    p_review_note: reviewNote,
    p_extracted_document_ref: extractedDocumentRef,
    p_extracted_document_date: extractedDocumentDate,
    p_extracted_currency_code: extractedCurrencyCode,
    p_extracted_total_amount: extractedTotalAmount,
  });

  if (error) {
    redirect(`/internal/shipping-control/shipper-documents/${shippingDocumentId}?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/internal/shipping-control");
  revalidatePath("/internal/shipping-control/shipper-documents");
  revalidatePath(`/internal/shipping-control/shipper-documents/${shippingDocumentId}`);
  redirect(`/internal/shipping-control/shipper-documents/${shippingDocumentId}?success=${encodeURIComponent("Shipping document review updated")}`);
}
