"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
const readString=(f:FormData,k:string)=>{const v=f.get(k);return typeof v==="string"?v.trim():""};
const readNumber=(f:FormData,k:string)=>{const n=Number(readString(f,k));return Number.isFinite(n)?n:0};

export async function createOrderAction(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: operator } = await supabase.from("operators").select("id, importer_id, shipper_id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const retailerId = readString(formData, "retailer_id");
  const destinationHubId = readString(formData, "destination_hub_id");
  const sopVersion = readString(formData, "sop_version") || "v1";
  const screenshotUrl = readString(formData, "screenshot_url");

  const lineIndexes = Array.from(new Set(Array.from(formData.keys()).filter((k)=>k.startsWith("line_category_")).map((k)=>k.replace("line_category_",""))));
  const lines = lineIndexes.map((index)=>({ markup_category_id: readString(formData,`line_category_${index}`), qty: readNumber(formData,`line_qty_${index}`), amount_inc_vat_gbp: readNumber(formData,`line_amount_${index}`)})).filter((l)=>l.markup_category_id && l.qty>0 && l.amount_inc_vat_gbp>0);

  if (!retailerId || !destinationHubId || lines.length === 0) redirect("/importer/orders/new?error=Missing+required+order+inputs.");

  const totalQty = lines.reduce((s,l)=>s+l.qty,0);
  const totalAmount = lines.reduce((s,l)=>s+l.amount_inc_vat_gbp,0);

  const { data: createdOrder, error: orderError } = await supabase.from("orders").insert({
    order_ref: `ORD-${Date.now()}`,
    payment_auth_id: `AUTH-${Date.now()}`,
    importer_id: operator.importer_id,
    operator_id: operator.id,
    shipper_id: operator.shipper_id,
    retailer_id: retailerId,
    destination_hub_id: destinationHubId,
    order_type: "original",
    status: "pending_dva_funding",
    sop_version: sopVersion,
    total_qty_declared: totalQty,
    order_total_gbp_declared: Number(totalAmount.toFixed(2)),
  }).select("id").single();

  if (orderError || !createdOrder) redirect(`/importer/orders/new?error=${encodeURIComponent(orderError?.message ?? "Failed to create order")}`);
  const { error: linesError } = await supabase.from("order_category_lines").insert(lines.map((line)=>({
    order_id: createdOrder.id,
    markup_category_id: line.markup_category_id,
    qty: line.qty,
    amount_inc_vat_gbp: Number(line.amount_inc_vat_gbp.toFixed(2)),
    markup_pct_applied: 0,
    markup_gbp_calculated: 0,
  })));
  if (linesError) redirect(`/importer/orders/new?error=${encodeURIComponent(linesError.message)}`);

  if (screenshotUrl) await supabase.from("order_screenshots").insert({order_id: createdOrder.id,screenshot_url: screenshotUrl,uploaded_by_operator_id: operator.id,display_order: 1,note: "Original order screenshot"});

  revalidatePath("/importer");
  revalidatePath(`/importer/orders/${createdOrder.id}/operations`);
  redirect(`/importer/orders/${createdOrder.id}/operations?success=Order+created`);
}
