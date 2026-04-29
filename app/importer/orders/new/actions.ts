"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

  const { data: defaultCategory } = await supabase
    .from("markup_categories")
    .select("id")
    .eq("active", true)
    .or(`shipper_id.eq.${importer.shipper_id},shipper_id.is.null`)
    .order("category_name")
    .limit(1)
    .maybeSingle();
  if (!defaultCategory?.id) redirect("/importer/orders/new?error=No+default+category+configured.");

  const stamp = Date.now();
  const orderRef = `ORD-${stamp}`;
  const paymentAuthId = `AUTH-${stamp}`;

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .insert({
      order_ref: orderRef,
      payment_auth_id: paymentAuthId,
      importer_id: operatorImporter.importer_id,
      operator_id: operator.id,
      shipper_id: importer.shipper_id,
      retailer_id: retailerId,
      destination_hub_id: shipper.primary_hub_id,
      order_type: "original",
      status: "pending_dva_funding",
      sop_version: "v1",
      total_qty_declared: qty,
      order_total_gbp_declared: Math.round(amount * 100) / 100,
    })
    .select("id")
    .single();
  if (orderError || !order?.id) redirect(`/importer/orders/new?error=${encodeURIComponent(orderError?.message ?? "Failed to create order")}`);

  await supabase.from("order_category_lines").insert({
    order_id: order.id,
    markup_category_id: defaultCategory.id,
    qty,
    amount_inc_vat_gbp: Math.round(amount * 100) / 100,
    markup_pct_applied: 0,
    markup_gbp_calculated: 0,
  });

  const screenshotRows = screenshots.map((file, i) => ({
    order_id: order.id,
    screenshot_url: `upload://${order.id}/${i + 1}-${file.name}`,
    uploaded_by_operator_id: operator.id,
    display_order: i + 1,
    note: "Original order screenshot",
  }));
  await supabase.from("order_screenshots").insert(screenshotRows);

  revalidatePath("/importer");
  revalidatePath(`/importer/orders/${order.id}/operations`);
  redirect(`/importer/orders/${order.id}/operations?success=Pro+Forma+Quote+created&order_ref=${encodeURIComponent(orderRef)}&auth_ref=${encodeURIComponent(paymentAuthId)}`);
}
