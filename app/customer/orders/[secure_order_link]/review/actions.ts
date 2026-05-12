"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const read = (formData: FormData, key: string) => {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
};

const optionalUuid = (value: string) => value || null;
const readAll = (formData: FormData, key: string) =>
  formData.getAll(key).map((value) => typeof value === "string" ? value.trim() : "").filter(Boolean);

export async function submitCustomerHoldRequestAction(formData: FormData) {
  const supabase = await createClient();
  const secureToken = read(formData, "secure_token");
  const requestedScope = read(formData, "requested_scope");
  const trackingSubmissionId = optionalUuid(read(formData, "tracking_submission_id"));
  const supplierInvoiceLineId = optionalUuid(read(formData, "supplier_invoice_line_id"));
  const supplierInvoiceLineIds = readAll(formData, "supplier_invoice_line_ids");
  const reason = read(formData, "reason");
  const customerContactLabel = read(formData, "customer_contact_label");

  if (!secureToken) redirect("/customer/orders/invalid/review?error=Missing+secure+link");
  if (!requestedScope) redirect(`/customer/orders/${secureToken}/review?error=Select+what+you+want+held`);
  if (!reason) redirect(`/customer/orders/${secureToken}/review?error=Please+give+a+reason+for+the+hold`);

  if (requestedScope === "line" && supplierInvoiceLineIds.length > 0) {
    const { error } = await (supabase as any).rpc("customer_submit_pre_shipment_line_holds_v1", {
      p_secure_token: secureToken,
      p_supplier_invoice_line_ids: supplierInvoiceLineIds,
      p_reason: reason,
      p_customer_contact_label: customerContactLabel || null,
    });

    if (error) {
      redirect(`/customer/orders/${secureToken}/review?error=${encodeURIComponent(error.message)}`);
    }

    redirect(`/customer/orders/${secureToken}/review?success=${encodeURIComponent(`${supplierInvoiceLineIds.length} line hold request(s) submitted`)}`);
  }

  if (requestedScope === "line" && !supplierInvoiceLineId) {
    redirect(`/customer/orders/${secureToken}/review?error=Select+at+least+one+item+line`);
  }

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
  const supplierInvoiceLineIds = readAll(formData, "supplier_invoice_line_ids");
  const reason = read(formData, "reason");

  if (!secureToken) redirect("/customer/orders/invalid/review?error=Missing+secure+link");
  if (!existingHoldRequestId) redirect(`/customer/orders/${secureToken}/review?error=Missing+existing+hold`);
  if (!requestedScope) redirect(`/customer/orders/${secureToken}/review?error=Select+what+you+want+held`);

  if (requestedScope === "line" && supplierInvoiceLineIds.length > 0) {
    const { error } = await (supabase as any).rpc("customer_narrow_pre_shipment_hold_lines_v1", {
      p_secure_token: secureToken,
      p_existing_hold_request_id: existingHoldRequestId,
      p_supplier_invoice_line_ids: supplierInvoiceLineIds,
      p_reason: reason || null,
    });

    if (error) {
      redirect(`/customer/orders/${secureToken}/review?error=${encodeURIComponent(error.message)}`);
    }

    redirect(`/customer/orders/${secureToken}/review?success=${encodeURIComponent(`Hold narrowed to ${supplierInvoiceLineIds.length} item line(s)`)}`);
  }

  if (requestedScope === "line" && !supplierInvoiceLineId) {
    redirect(`/customer/orders/${secureToken}/review?error=Select+at+least+one+item+line`);
  }

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
