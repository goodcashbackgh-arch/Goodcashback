"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const read = (formData: FormData, key: string) => {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
};

export async function createCustomerReviewLinkAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = read(formData, "order_id");

  if (!orderId) redirect("/internal/customer-holds?error=Order+ID+is+required");

  const { data, error } = await (supabase as any).rpc("internal_create_customer_order_review_link_v1", {
    p_order_id: orderId,
  });

  if (error) {
    redirect(`/internal/customer-holds?error=${encodeURIComponent(error.message)}`);
  }

  const row = Array.isArray(data) ? data[0] : data;
  const path = row?.customer_review_path || "";
  revalidatePath("/internal/customer-holds");
  redirect(`/internal/customer-holds?success=${encodeURIComponent("Customer review link ready")}&link=${encodeURIComponent(path)}`);
}

export async function reviewCustomerHoldAction(formData: FormData) {
  const supabase = await createClient();
  const holdRequestId = read(formData, "hold_request_id");
  const decision = read(formData, "decision");
  const reviewNote = read(formData, "review_note");

  if (!holdRequestId) redirect("/internal/customer-holds?error=Missing+hold+request");
  if (!decision) redirect("/internal/customer-holds?error=Missing+review+decision");

  const { error } = await (supabase as any).rpc("internal_review_customer_pre_shipment_hold_v1", {
    p_hold_request_id: holdRequestId,
    p_decision: decision,
    p_review_note: reviewNote || null,
  });

  if (error) {
    redirect(`/internal/customer-holds?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath("/internal/customer-holds");
  revalidatePath("/shipper");
  revalidatePath("/shipper/customer-holds");
  revalidatePath("/internal/sage-ready");
  revalidatePath("/internal/status-control/pre-sage-financial-readiness");
  redirect(`/internal/customer-holds?success=${encodeURIComponent("Customer hold updated")}`);
}
