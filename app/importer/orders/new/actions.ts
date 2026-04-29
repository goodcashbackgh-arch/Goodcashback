"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const ORDER_SCREENSHOTS_BUCKET = "order-screenshots";

const readString = (f: FormData, k: string) => {
  const v = f.get(k);
  return typeof v === "string" ? v.trim() : "";
};

export async function createOrderAction(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: operatorImporter } = await supabase.from("operator_importers").select("importer_id").eq("operator_id", operator.id).is("revoked_at", null).limit(1).maybeSingle();
  if (!operatorImporter?.importer_id) redirect("/importer/orders/new?error=No+active+importer+assignment.");

  const { data: importer } = await supabase.from("importers").select("shipper_id").eq("id", operatorImporter.importer_id).maybeSingle();
  if (!importer?.shipper_id) redirect("/importer/orders/new?error=Importer+record+missing+shipper.");

  const retailerId = readString(formData, "retailer_id");
  const destinationHubId = readString(formData, "destination_hub_id");
  const totalQty = Number(readString(formData, "total_qty_declared"));
  const totalAmount = Math.round(Number(readString(formData, "order_total_gbp_declared")) * 100) / 100;
  const confirmed = readString(formData, "product_confirmed") === "yes";
  const screenshots = formData.getAll("screenshots").filter((f): f is File => f instanceof File && f.size > 0);

  if (!retailerId) redirect("/importer/orders/new?error=Retailer+is+required.");
  if (!confirmed) redirect("/importer/orders/new?error=Product+confirmation+is+required.");
  if (screenshots.length < 1) redirect("/importer/orders/new?error=At+least+one+screenshot+is+required.");
  if (!destinationHubId) redirect("/importer/orders/new?error=Destination+hub+is+required.");
  if (!Number.isInteger(totalQty) || totalQty <= 0) redirect("/importer/orders/new?error=Total+qty+declared+must+be+a+positive+integer.");
  if (!Number.isFinite(totalAmount) || totalAmount <= 0) redirect("/importer/orders/new?error=Order+total+GBP+declared+must+be+greater+than+0.");

  const { data: validRetailer } = await supabase
    .from("shipper_retailers")
    .select("retailer_id")
    .eq("shipper_id", importer.shipper_id)
    .eq("retailer_id", retailerId)
    .eq("enabled", true)
    .maybeSingle();
  if (!validRetailer?.retailer_id) redirect("/importer/orders/new?error=Retailer+is+not+enabled+for+your+shipper.");

  const { data: validHub } = await supabase
    .from("hubs")
    .select("id")
    .eq("id", destinationHubId)
    .eq("shipper_id", importer.shipper_id)
    .eq("active", true)
    .maybeSingle();
  if (!validHub?.id) redirect("/importer/orders/new?error=Destination+hub+is+not+valid+for+your+shipper.");

  const stamp = Date.now();
  const orderRef = `ORD-${stamp}`;
  const paymentAuthId = `AUTH-${stamp}`;
  const { data: createdOrder, error: orderError } = await supabase
    .from("orders")
    .insert({
      order_ref: orderRef,
      payment_auth_id: paymentAuthId,
      importer_id: operatorImporter.importer_id,
      operator_id: operator.id,
      shipper_id: importer.shipper_id,
      retailer_id: retailerId,
      destination_hub_id: destinationHubId,
      order_type: "main",
      status: "pending_dva_funding",
      sop_version: "v1",
      total_qty_declared: totalQty,
      order_total_gbp_declared: totalAmount,
    })
    .select("id")
    .single();

  if (orderError || !createdOrder?.id) {
    redirect(`/importer/orders/new?error=${encodeURIComponent(orderError?.message ?? "Failed to create order")}`);
  }
  const createdOrderId = createdOrder.id;

  const uploadedUrls: string[] = [];
  for (let i = 0; i < screenshots.length; i += 1) {
    const file = screenshots[i];
    const ext = file.name.includes(".") ? file.name.split(".").pop() : "bin";
    const safeExt = (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
    const objectPath = `${operatorImporter.importer_id}/${createdOrderId}/${i + 1}-${Date.now()}.${safeExt}`;
    const { error: uploadError } = await supabase.storage.from(ORDER_SCREENSHOTS_BUCKET).upload(objectPath, file, { upsert: false });
    if (uploadError) {
      redirect(`/importer/orders/new?error=${encodeURIComponent(`Screenshot upload failed. Ensure bucket '${ORDER_SCREENSHOTS_BUCKET}' exists and is writable. ${uploadError.message}`)}`);
    }
    const { data: publicUrlData } = supabase.storage.from(ORDER_SCREENSHOTS_BUCKET).getPublicUrl(objectPath);
    uploadedUrls.push(publicUrlData.publicUrl || objectPath);
  }

  const screenshotRows = uploadedUrls.map((screenshotUrl, i) => ({
    order_id: createdOrderId,
    screenshot_url: screenshotUrl,
    uploaded_by_operator_id: operator.id,
    display_order: i + 1,
    note: "Original order screenshot",
  }));
  const { error: screenshotInsertError } = await supabase.from("order_screenshots").insert(screenshotRows);
  if (screenshotInsertError) redirect(`/importer/orders/new?error=${encodeURIComponent(screenshotInsertError.message)}`);

  revalidatePath("/importer");
  revalidatePath(`/importer/orders/${createdOrderId}/operations`);
  redirect(`/importer/orders/${createdOrderId}/operations?success=Pro+Forma+Quote+created&order_ref=${encodeURIComponent(orderRef)}&auth_ref=${encodeURIComponent(paymentAuthId)}`);
}
