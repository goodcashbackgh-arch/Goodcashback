"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const read = (formData: FormData, key: string) => {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
};

const nullableUuid = (value: string) => value || null;

export async function submitCustomerHoldRequestAction(formData: FormData) {
  const supabase = await createClient();
  const token = read(formData, "secure_token");
  const requestedScope = read(formData, "requested_scope");
  const trackingSubmissionId = read(formData, "tracking_submission_id");
  const supplierInvoiceLineId = read(formData, "supplier_invoice_line_id");
  const reason = read(formData, "reason");
  const customerContactLabel = read(formData, "customer_contact_label");

  if (!token) redirect("/customer?error=Missing+customer+review+token");
  if (!requestedScope) redirect(`/customer/orders/${token}/review?error=${encodeURIComponent("Choose what you want us to hold before shipping.")}`);
  if (!reason) redirect(`/customer/orders/${token}/review?error=${encodeURIComponent("Please explain why you want this held.")}`);

  const { error } = await (supabase as any).rpc("customer_submit_pre_shipment_hold_request_v1", {
    p_secure_token: token,
    p_requested_scope: requestedScope,
    p_tracking_submission_id: nullableUuid(trackingSubmissionId),
    p_supplier_invoice_line_id: nullableUuid(supplierInvoiceLineId),
    p_reason: reason,
    p_customer_contact_label: customerContactLabel || null,
  });

  if (error) {
    redirect(`/customer/orders/${token}/review?error=${encodeURIComponent(error.message)}`);
  }

  revalidatePath(`/customer/orders/${token}/review`);
  revalidatePath("/internal/customer-holds");
  redirect(`/customer/orders/${token}/review?success=${encodeURIComponent("Hold request submitted. We will review it before shipping.")}`);
}
