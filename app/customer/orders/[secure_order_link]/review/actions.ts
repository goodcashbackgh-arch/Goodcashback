"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const read = (formData: FormData, key: string) => {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
};

const optionalUuid = (value: string) => value || null;

export async function submitCustomerHoldRequestAction(formData: FormData) {
  const supabase = await createClient();
  const secureToken = read(formData, "secure_token");
  const requestedScope = read(formData, "requested_scope");
  const trackingSubmissionId = optionalUuid(read(formData, "tracking_submission_id"));
  const supplierInvoiceLineId = optionalUuid(read(formData, "supplier_invoice_line_id"));
  const reason = read(formData, "reason");
  const customerContactLabel = read(formData, "customer_contact_label");

  if (!secureToken) redirect("/customer/orders/invalid/review?error=Missing+secure+link");
  if (!requestedScope) redirect(`/customer/orders/${secureToken}/review?error=Select+what+you+want+held`);
  if (!reason) redirect(`/customer/orders/${secureToken}/review?error=Please+give+a+reason+for+the+hold`);

  const { error } = await (supabase as any).rpc("customer_submit_pre_shipment_hold_request_v1", {
    p_secure_token: secureToken,
    p_requested_scope: requestedScope,
    p_tracking_submission_id: trackingSubmissionId,
    p_supplier_invoice_line_id: supplierInvoiceLineId,
    p_reason: reason,
    p_customer_contact_label: customerContactLabel || null,
  });

  if (error) {
    redirect(`/customer/orders/${secureToken}/review?error=${encodeURIComponent(error.message)}`);
  }

  redirect(`/customer/orders/${secureToken}/review?success=Hold+request+submitted`);
}

export async function narrowCustomerHoldRequestAction(formData: FormData) {
  const supabase = await createClient();
  const secureToken = read(formData, "secure_token");
  const existingHoldRequestId = read(formData, "existing_hold_request_id");
  const requestedScope = read(formData, "requested_scope");
  const trackingSubmissionId = optionalUuid(read(formData, "tracking_submission_id"));
  const supplierInvoiceLineId = optionalUuid(read(formData, "supplier_invoice_line_id"));
  const reason = read(formData, "reason");

  if (!secureToken) redirect("/customer/orders/invalid/review?error=Missing+secure+link");
  if (!existingHoldRequestId) redirect(`/customer/orders/${secureToken}/review?error=Missing+existing+hold`);
  if (!requestedScope) redirect(`/customer/orders/${secureToken}/review?error=Select+what+you+want+held`);

  const { error } = await (supabase as any).rpc("customer_narrow_pre_shipment_hold_request_v1", {
    p_secure_token: secureToken,
    p_existing_hold_request_id: existingHoldRequestId,
    p_requested_scope: requestedScope,
    p_tracking_submission_id: trackingSubmissionId,
    p_supplier_invoice_line_id: supplierInvoiceLineId,
    p_reason: reason || null,
  });

  if (error) {
    redirect(`/customer/orders/${secureToken}/review?error=${encodeURIComponent(error.message)}`);
  }

  redirect(`/customer/orders/${secureToken}/review?success=Hold+narrowed+to+available+detail`);
}
