"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { runMindeeOcrAfterUpload } from "./ocr";

const BUCKET = "invoice-evidence";

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function money(formData: FormData, key: string) {
  const raw = text(formData, key);
  if (!raw) return 0;
  const value = Math.round(Number(raw) * 100) / 100;
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

async function requireOperatorAccess(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orderId: string,
) {
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
  if (!order?.importer_id) {
    redirect(`/importer/orders/${orderId}/operations?error=Order+not+found`);
  }

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) {
    redirect(`/importer/orders/${orderId}/operations?error=No+access+to+this+order`);
  }

  return {
    operatorId: operator.id as string,
    importerId: order.importer_id as string,
    shipperId: order.shipper_id as string,
  };
}

async function deliveryLimit(
  supabase: Awaited<ReturnType<typeof createClient>>,
  shipperId: string,
) {
  const { data: shipperPolicy } = await supabase
    .from("order_adjustment_policy")
    .select("delivery_auto_approve_limit_gbp")
    .eq("shipper_id", shipperId)
    .eq("active", true)
    .maybeSingle();
  if (shipperPolicy?.delivery_auto_approve_limit_gbp != null) {
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

export async function submitAdditionalInvoiceEvidenceAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = text(formData, "order_id");
  const invoiceRef = text(formData, "invoice_ref");
  const invoiceTotal = money(formData, "invoice_total_gbp");
  const deliveryCharge = money(formData, "retailer_delivery_gbp");
  const discountAmount = money(formData, "retailer_discount_gbp");
  const invoiceFile = formData.get("invoice_file");

  if (!orderId) redirect("/importer?error=Missing+order+id");
  if (!invoiceRef) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+reference+is+required`);
  }
  if (invoiceTotal <= 0) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+total+GBP+is+required`);
  }
  if (!(invoiceFile instanceof File) || invoiceFile.size <= 0) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+file+is+required`);
  }

  const { operatorId, importerId, shipperId } = await requireOperatorAccess(supabase, orderId);
  const objectPath = `${importerId}/${orderId}/supplier-invoices/${Date.now()}-${crypto.randomUUID()}.${safeExt(invoiceFile.name)}`;
  const { error: uploadError } = await supabase.storage
    .from(BUCKET)
    .upload(objectPath, invoiceFile, { upsert: false });
  if (uploadError) {
    redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(uploadError.message)}`);
  }

  const { data: publicUrlData } = supabase.storage.from(BUCKET).getPublicUrl(objectPath);
  const invoicePdfUrl = publicUrlData.publicUrl || objectPath;
  const { data: invoiceResult, error: submitError } = await supabase.rpc(
    "operator_submit_supplier_invoice",
    {
      p_order_id: orderId,
      p_invoice_ref: invoiceRef,
      p_invoice_pdf_url: invoicePdfUrl,
    },
  );

  if (submitError) {
    await supabase.storage.from(BUCKET).remove([objectPath]);
    redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(submitError.message)}`);
  }

  const supplierInvoiceId =
    typeof invoiceResult === "object" && invoiceResult && "supplier_invoice_id" in invoiceResult
      ? String(invoiceResult.supplier_invoice_id)
      : "";
  if (!supplierInvoiceId) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+created+without+an+invoice+id`);
  }

  const { error: summaryError } = await supabase
    .from("supplier_invoice_financial_summary")
    .insert({
      supplier_invoice_id: supplierInvoiceId,
      invoice_total_gbp: invoiceTotal,
      source: "operator_entered",
      confidence: "medium",
      entered_by_operator_id: operatorId,
      notes: "Additional supplier invoice total entered by operator during upload.",
    });
  if (summaryError) {
    redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(summaryError.message)}`);
  }

  const adjustments: Array<Record<string, unknown>> = [];
  if (deliveryCharge > 0) {
    const limit = await deliveryLimit(supabase, shipperId);
    const autoApproved = deliveryCharge <= limit;
    adjustments.push({
      order_id: orderId,
      supplier_invoice_id: supplierInvoiceId,
      adjustment_type: "retailer_delivery",
      amount_gbp: deliveryCharge,
      approval_status: autoApproved ? "auto_approved" : "pending_supervisor",
      requires_supervisor_approval: !autoApproved,
      submitted_by_operator_id: operatorId,
      apportionment_method: "pro_rata_by_line_value",
      customer_treatment: "pass_to_importer",
      notes: autoApproved
        ? `Auto-approved retailer delivery charge within GBP ${limit} limit.`
        : `Retailer delivery charge exceeds GBP ${limit} auto-approval limit.`,
    });
  }
  if (discountAmount > 0) {
    adjustments.push({
      order_id: orderId,
      supplier_invoice_id: supplierInvoiceId,
      adjustment_type: "retailer_discount",
      amount_gbp: discountAmount,
      approval_status: "pending_supervisor",
      requires_supervisor_approval: true,
      submitted_by_operator_id: operatorId,
      apportionment_method: "pro_rata_by_line_value",
      customer_treatment: "pass_to_importer",
      notes: "Retailer discount submitted with additional supplier invoice.",
    });
  }
  if (adjustments.length > 0) {
    const { error: adjustmentError } = await supabase.from("order_value_adjustments").insert(adjustments);
    if (adjustmentError) {
      redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(adjustmentError.message)}`);
    }
  }

  if (process.env.MINDEE_AUTO_RUN_ON_UPLOAD === "true") {
    try {
      await runMindeeOcrAfterUpload({
        supplierInvoiceId,
        orderId,
        invoicePdfUrl,
        enteredInvoiceTotal: invoiceTotal,
        operatorId,
      });
    } catch (error) {
      redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(error instanceof Error ? error.message : "OCR failed")}`);
    }
  }

  revalidatePath(`/importer/orders/${orderId}/operations`);
  revalidatePath(`/importer/reconciliation/${orderId}`);
  revalidatePath(`/internal/evidence/${orderId}`);
  revalidatePath(`/internal/reconciliation/${orderId}`);
  redirect(`/importer/orders/${orderId}/operations?success=${encodeURIComponent(`Invoice ${invoiceRef} uploaded. You can add another genuine invoice reference if the retailer split the order again.`)}`);
}
