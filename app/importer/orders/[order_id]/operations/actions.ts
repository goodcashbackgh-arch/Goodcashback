"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const INVOICE_EVIDENCE_BUCKET = "invoice-evidence";

const rs = (f: FormData, k: string) => {
  const v = f.get(k);
  return typeof v === "string" ? v.trim() : "";
};

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
    .select("importer_id")
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

  return { operator, importerId: order.importer_id as string };
}

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
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
  const invoiceFile = formData.get("invoice_file");

  if (!orderId) redirect("/importer?error=Missing+order+id");
  if (!invoiceRef) redirect(`/importer/orders/${orderId}/operations?error=Invoice+reference+is+required`);
  if (!(invoiceFile instanceof File) || invoiceFile.size <= 0) {
    redirect(`/importer/orders/${orderId}/operations?error=Invoice+file+is+required`);
  }

  const { importerId } = await requireOperatorAccess(supabase, orderId);
  const objectPath = `${importerId}/${orderId}/${Date.now()}.${safeExt(invoiceFile.name)}`;
  const { error: uploadError } = await supabase.storage
    .from(INVOICE_EVIDENCE_BUCKET)
    .upload(objectPath, invoiceFile, { upsert: false });

  if (uploadError) {
    redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(`Invoice upload failed. Ensure bucket '${INVOICE_EVIDENCE_BUCKET}' exists and is writable. ${uploadError.message}`)}`);
  }

  const { data: publicUrlData } = supabase.storage.from(INVOICE_EVIDENCE_BUCKET).getPublicUrl(objectPath);
  const invoicePdfUrl = publicUrlData.publicUrl || objectPath;

  const { error } = await supabase.rpc("operator_submit_supplier_invoice", {
    p_order_id: orderId,
    p_invoice_ref: invoiceRef,
    p_invoice_pdf_url: invoicePdfUrl,
  });

  if (error) redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(error.message)}`);
  revalidatePath(`/importer/orders/${orderId}/operations`);
  revalidatePath("/importer");
  redirect(`/importer/orders/${orderId}/operations?success=Invoice+submitted`);
}
