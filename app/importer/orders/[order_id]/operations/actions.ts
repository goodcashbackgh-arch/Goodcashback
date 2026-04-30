"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const INVOICE_EVIDENCE_BUCKET = "invoice-evidence";

const rs = (f: FormData, k: string) => {
  const v = f.get(k);
  return typeof v === "string" ? v.trim() : "";
};

function readMoney(f: FormData, k: string) {
  const raw = rs(f, k);
  if (!raw) return 0;
  const value = Math.round(Number(raw) * 100) / 100;
  return Number.isFinite(value) && value > 0 ? value : 0;
}

async function requireOperatorAccess(supabase: Awaited<ReturnType<typeof createClient>>, orderId: string) {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: order } = await supabase
    .from("orders")
    .select("importer_id, shipper_id")
    .eq("id", orderId)
    .maybeSingle();
  if (!order?.importer_id) redirect(`/importer/orders/${orderId}/operations?error=Order+not+found`);

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) redirect(`/importer/orders/${orderId}/operations?error=No+access+to+this+order`);

  return { operator, importerId: order.importer_id as string, shipperId: order.shipper_id as string };
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

async function getDeliveryLimit(supabase: Awaited<ReturnType<typeof createClient>>, shipperId: string) {
  const { data: shipperPolicy } = await supabase
    .from("order_adjustment_policy")
    .select("delivery_auto_approve_limit_gbp")
    .eq("shipper_id", shipperId)
    .eq("active", true)
    .maybeSingle();

  if (shipperPolicy?.delivery_auto_approve_limit_gbp !== undefined && shipperPolicy?.delivery_auto_approve_limit_gbp !== null) {
    return Number(shipperPolicy.delivery_auto_approve_limit_gbp);
  }

  const { data: globalPolicy } = await supabase
    .from("order_adjustment_policy")
    .select("delivery_auto_approve_limit_gbp")
    .is("shipper_id", null)
    .eq("active", true)
    .maybeSingle();

  return Number(globalPolicy?.delivery_auto_approve_limit_gbp ?? 10);
}

export async function addTrackingSubmissionAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = rs(formData, "order_id");
  const courierId = rs(formData, "courier_id");
  const trackingRef = rs(formData, "tracking_ref");
  const trackingDate = rs(formData, "tracking_date");
  const trackingScreenshotUrl = rs(formData, "tracking_screenshot_url") || null;
  const note = rs(formData, "note") || null;
  const isFinalDelivery = rs(formData, "is_final_delivery_yn") === "on";

  if (!orderId) redirect("/importer?error=Missing+order+id");
  const { operator } = await requireOperatorAccess(supabase, orderId);

  const { error } = await supabase.rpc("importer_add_order_tracking_submission", {
    p_order_id: orderId,
    p_operator_id: operator.id,
    p_courier_id: courierId,
    p_tracking_ref: trackingRef,
    p_tracking_date: trackingDate,
    p_tracking_screenshot_url: trackingScreenshotUrl,
    p_note: note,
    p_is_final_delivery_yn: isFinalDelivery,
  });
  if (error) redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(error.message)}`);
  revalidatePath(`/importer/orders/${orderId}/operations`);
  redirect(`/importer/orders/${orderId}/operations?success=Tracking+added`);
}

export async function submitInvoiceEvidenceAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = rs(formData, "order_id");
  const invoiceRef = rs(formData, "invoice_ref");
  const invoiceTotal = readMoney(formData, "invoice_total_gbp");
  const invoiceFile = formData.get("invoice_file");
  const deliveryCharge = readMoney(formData, "retailer_delivery_gbp");
  const discountAmount = readMoney(formData, "retailer_discount_gbp");

  if (!orderId) redirect("/importer?error=Missing+order+id");
  if (!invoiceRef) redirect(`/importer/orders/${orderId}/operations?error=Invoice+reference+is+required`);
  if (invoiceTotal <= 0) redirect(`/importer/orders/${orderId}/operations?error=Invoice+total+GBP+is+required`);
  if (!(invoiceFile instanceof File) || invoiceFile.size <= 0) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+file+is+required`);
  }

  const { operator, importerId, shipperId } = await requireOperatorAccess(supabase, orderId);
  const objectPath = `${importerId}/${orderId}/${Date.now()}.${safeExt(invoiceFile.name)}`;
  const { error: uploadError } = await supabase.storage
    .from(INVOICE_EVIDENCE_BUCKET)
    .upload(objectPath, invoiceFile, { upsert: false });

  if (uploadError) {
    redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(`Invoice upload failed. Ensure bucket '${INVOICE_EVIDENCE_BUCKET}' exists and is writable. ${uploadError.message}`)}`);
  }

  const { data: publicUrlData } = supabase.storage.from(INVOICE_EVIDENCE_BUCKET).getPublicUrl(objectPath);
  const invoicePdfUrl = publicUrlData.publicUrl || objectPath;

  const { data: invoiceResult, error } = await supabase.rpc("operator_submit_supplier_invoice", {
    p_order_id: orderId,
    p_invoice_ref: invoiceRef,
    p_invoice_pdf_url: invoicePdfUrl,
  });

  if (error) redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(error.message)}`);

  const supplierInvoiceId = typeof invoiceResult === "object" && invoiceResult && "supplier_invoice_id" in invoiceResult
    ? String(invoiceResult.supplier_invoice_id)
    : null;

  if (!supplierInvoiceId) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+created+but+supplier+invoice+id+was+not+returned`);
  }

  const { error: summaryError } = await supabase.from("supplier_invoice_financial_summary").insert({
    supplier_invoice_id: supplierInvoiceId,
    invoice_total_gbp: invoiceTotal,
    source: "operator_entered",
    confidence: "medium",
    entered_by_operator_id: operator.id,
    notes: "Supplier invoice total entered by operator during invoice upload.",
  });

  if (summaryError) {
    redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(summaryError.message)}`);
  }

  const adjustmentRows = [];
  if (deliveryCharge > 0) {
    const deliveryLimit = await getDeliveryLimit(supabase, shipperId);
    const autoApproved = deliveryCharge <= deliveryLimit;
    adjustmentRows.push({
      order_id: orderId,
      supplier_invoice_id: supplierInvoiceId,
      adjustment_type: "retailer_delivery",
      amount_gbp: deliveryCharge,
      approval_status: autoApproved ? "auto_approved" : "pending_supervisor",
      requires_supervisor_approval: !autoApproved,
      submitted_by_operator_id: operator.id,
      apportionment_method: "pro_rata_by_line_value",
      customer_treatment: "pass_to_importer",
      notes: autoApproved ? `Auto-approved retailer delivery charge within GBP ${deliveryLimit} limit.` : `Retailer delivery charge exceeds GBP ${deliveryLimit} auto-approval limit.`,
    });
  }

  if (discountAmount > 0) {
    adjustmentRows.push({
      order_id: orderId,
      supplier_invoice_id: supplierInvoiceId,
      adjustment_type: "retailer_discount",
      amount_gbp: discountAmount,
      approval_status: "pending_supervisor",
      requires_supervisor_approval: true,
      submitted_by_operator_id: operator.id,
      apportionment_method: "pro_rata_by_line_value",
      customer_treatment: "pass_to_importer",
      notes: "Retailer discount requires supervisor approval before final invoice drafting.",
    });
  }

  if (adjustmentRows.length > 0) {
    const { error: adjustmentError } = await supabase.from("order_value_adjustments").insert(adjustmentRows);
    if (adjustmentError) {
      redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(adjustmentError.message)}`);
    }
  }

  revalidatePath(`/importer/orders/${orderId}/operations`);
  revalidatePath(`/importer/reconciliation/${orderId}`);
  revalidatePath("/importer");
  redirect(`/importer/orders/${orderId}/operations?success=Invoice+submitted`);
}
