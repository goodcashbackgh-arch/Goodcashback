"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const rs=(f:FormData,k:string)=>{const v=f.get(k);return typeof v==="string"?v.trim():""};
export async function addTrackingSubmissionAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = rs(formData,"order_id");
  const courierId = rs(formData,"courier_id");
  const trackingRef = rs(formData,"tracking_ref");
  const trackingDate = rs(formData,"tracking_date");
  const trackingScreenshotUrl = rs(formData,"tracking_screenshot_url") || null;
  const note = rs(formData,"note") || null;
  const isFinalDelivery = rs(formData,"is_final_delivery_yn") === "on";

  const {data:{user}} = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) redirect("/auth/check");
  const { data: order } = await supabase.from("orders").select("importer_id").eq("id", orderId).maybeSingle();
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
