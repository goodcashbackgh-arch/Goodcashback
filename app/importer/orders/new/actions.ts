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
  const confirmed = readString(formData, "product_confirmed") === "yes";
  const screenshots = formData.getAll("screenshots").filter((f): f is File => f instanceof File && f.size > 0);

  if (!retailerId) redirect("/importer/orders/new?error=Retailer+is+required.");
  if (!confirmed) redirect("/importer/orders/new?error=Product+confirmation+is+required.");
  if (screenshots.length < 1) redirect("/importer/orders/new?error=At+least+one+screenshot+is+required.");
  if (!destinationHubId) redirect("/importer/orders/new?error=Destination+hub+is+required.");

  const { data: validHubs } = await supabase.from("hubs").select("id").eq("shipper_id", importer.shipper_id).eq("active", true);
  const validHubIds = new Set((validHubs ?? []).map((h) => h.id));
  if (!validHubIds.has(destinationHubId)) redirect("/importer/orders/new?error=Destination+hub+is+not+valid+for+your+shipper.");

  const lineCategoryIds = formData.getAll("line_category_id").map((v) => (typeof v === "string" ? v.trim() : "")).filter(Boolean);
  const lineQtys = formData.getAll("line_qty").map((v) => Number(typeof v === "string" ? v : ""));
  const lineAmounts = formData.getAll("line_amount").map((v) => Number(typeof v === "string" ? v : ""));
  if (lineCategoryIds.length === 0 || lineQtys.length !== lineCategoryIds.length || lineAmounts.length !== lineCategoryIds.length) {
    redirect("/importer/orders/new?error=At+least+one+valid+category+line+is+required.");
  }

  const { data: allowedCategories } = await supabase
    .from("markup_categories")
    .select("id")
    .eq("active", true)
    .or(`shipper_id.eq.${importer.shipper_id},shipper_id.is.null`);
  const allowedCategoryIds = new Set((allowedCategories ?? []).map((c) => c.id));

  const lines = lineCategoryIds.map((categoryId, idx) => ({
    markup_category_id: categoryId,
    qty: lineQtys[idx],
    amount_inc_vat_gbp: Math.round(lineAmounts[idx] * 100) / 100,
  }));

  if (lines.some((l) => !allowedCategoryIds.has(l.markup_category_id) || !Number.isInteger(l.qty) || l.qty <= 0 || !Number.isFinite(l.amount_inc_vat_gbp) || l.amount_inc_vat_gbp <= 0)) {
    redirect("/importer/orders/new?error=Each+category+line+must+have+a+valid+category,+positive+integer+qty,+and+positive+GBP+amount.");
  }

  const totalQty = lines.reduce((s, l) => s + l.qty, 0);
  const totalAmount = Math.round(lines.reduce((s, l) => s + l.amount_inc_vat_gbp, 0) * 100) / 100;
  if (totalQty <= 0 || totalAmount <= 0) redirect("/importer/orders/new?error=Order+totals+must+be+greater+than+0.");

  const stamp = Date.now();
  const orderRef = `ORD-${stamp}`;
  const paymentAuthId = `AUTH-${stamp}`;
  const { data: createdOrderId, error: orderError } = await supabase.rpc("importer_create_order_with_lines", {
    p_operator_id: operator.id,
    p_importer_id: operatorImporter.importer_id,
    p_shipper_id: importer.shipper_id,
    p_retailer_id: retailerId,
    p_destination_hub_id: destinationHubId,
    p_sop_version: "v1",
    p_order_type: "original",
    p_order_ref: orderRef,
    p_payment_auth_id: paymentAuthId,
    p_screenshot_url: null,
    p_lines: lines,
  });

  if (orderError || !createdOrderId) {
    redirect(`/importer/orders/new?error=${encodeURIComponent(orderError?.message ?? "Failed to create order")}`);
  }

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
