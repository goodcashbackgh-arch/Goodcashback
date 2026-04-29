"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const ORDER_SCREENSHOTS_BUCKET = "order-screenshots";
const GENERAL_CATEGORY_NAME = "General goods";

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

  const { data: shipper } = await supabase.from("shippers").select("primary_hub_id").eq("id", importer.shipper_id).maybeSingle();
  if (!shipper?.primary_hub_id) redirect("/importer/orders/new?error=Shipper+missing+assigned+destination+hub.");

  const retailerId = readString(formData, "retailer_id");
  const qty = Number(readString(formData, "line_qty"));
  const amount = Number(readString(formData, "line_amount"));
  const confirmed = readString(formData, "product_confirmed") === "yes";
  const screenshots = formData.getAll("screenshots").filter((f): f is File => f instanceof File && f.size > 0);

  if (!retailerId) redirect("/importer/orders/new?error=Retailer+is+required.");
  if (!confirmed) redirect("/importer/orders/new?error=Product+confirmation+is+required.");
  if (screenshots.length < 1) redirect("/importer/orders/new?error=At+least+one+screenshot+is+required.");
  if (!Number.isFinite(qty) || qty <= 0 || !Number.isFinite(amount) || amount <= 0) redirect("/importer/orders/new?error=Qty+and+amount+must+be+greater+than+0.");

  let generalCategoryId: string | null = null;
  const withCode = await supabase
    .from("markup_categories")
    .select("id")
    .eq("active", true)
    .eq("category_code", "general_goods")
    .or(`shipper_id.eq.${importer.shipper_id},shipper_id.is.null`)
    .limit(1)
    .maybeSingle();

  if (!withCode.error && withCode.data?.id) {
    generalCategoryId = withCode.data.id;
  } else {
    const byName = await supabase
      .from("markup_categories")
      .select("id")
      .eq("active", true)
      .eq("category_name", GENERAL_CATEGORY_NAME)
      .or(`shipper_id.eq.${importer.shipper_id},shipper_id.is.null`)
      .limit(1)
      .maybeSingle();
    if (byName.data?.id) generalCategoryId = byName.data.id;
  }

  if (!generalCategoryId) redirect("/importer/orders/new?error=General+goods+category+is+not+configured.");

  const stamp = Date.now();
  const orderRef = `ORD-${stamp}`;
  const paymentAuthId = `AUTH-${stamp}`;
  const lines = [{ markup_category_id: generalCategoryId, qty, amount_inc_vat_gbp: Math.round(amount * 100) / 100 }];

  const { data: createdOrderId, error: orderError } = await supabase.rpc("importer_create_order_with_lines", {
    p_operator_id: operator.id,
    p_importer_id: operatorImporter.importer_id,
    p_shipper_id: importer.shipper_id,
    p_retailer_id: retailerId,
    p_destination_hub_id: shipper.primary_hub_id,
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
