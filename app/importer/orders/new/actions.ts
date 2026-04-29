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
  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");
  const { data: operatorImporter } = await supabase
    .from("operator_importers")
    .select("importer_id")
    .eq("operator_id", operator.id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!operatorImporter?.importer_id) redirect("/importer/orders/new?error=No+active+importer+assignment.");
  const { data: importer } = await supabase.from("importers").select("shipper_id").eq("id", operatorImporter.importer_id).maybeSingle();
  if (!importer?.shipper_id) redirect("/importer/orders/new?error=Importer+record+missing+shipper.");

  const retailerId = readString(formData, "retailer_id");
  const destinationHubId = readString(formData, "destination_hub_id");
  const sopVersion = readString(formData, "sop_version") || "v1";
  const screenshotUrl = readString(formData, "screenshot_url");

  const lineIndexes = Array.from(new Set(Array.from(formData.keys()).filter((k)=>k.startsWith("line_category_")).map((k)=>k.replace("line_category_",""))));
  const lines = lineIndexes.map((index)=>({ markup_category_id: readString(formData,`line_category_${index}`), qty: readNumber(formData,`line_qty_${index}`), amount_inc_vat_gbp: readNumber(formData,`line_amount_${index}`)})).filter((l)=>l.markup_category_id && l.qty>0 && l.amount_inc_vat_gbp>0);

  if (!retailerId || !destinationHubId || lines.length === 0) redirect("/importer/orders/new?error=Missing+required+order+inputs.");

  const orderRef = `ORD-${Date.now()}`;
  const paymentAuthId = `AUTH-${Date.now()}`;
  const { data: createdOrderId, error: orderError } = await supabase.rpc("importer_create_order_with_lines", {
    p_operator_id: operator.id,
    p_importer_id: operatorImporter.importer_id,
    p_shipper_id: importer.shipper_id,
    p_retailer_id: retailerId,
    p_destination_hub_id: destinationHubId,
    p_sop_version: sopVersion,
    p_order_type: "original",
    p_order_ref: orderRef,
    p_payment_auth_id: paymentAuthId,
    p_screenshot_url: screenshotUrl || null,
    p_lines: lines,
  });
  if (orderError || !createdOrderId) redirect(`/importer/orders/new?error=${encodeURIComponent(orderError?.message ?? "Failed to create order")}`);

  revalidatePath("/importer");
  revalidatePath(`/importer/orders/${createdOrderId}/operations`);
  redirect(`/importer/orders/${createdOrderId}/operations?success=Order+created`);
}
