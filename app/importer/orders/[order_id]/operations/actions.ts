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

  const { error } = await supabase.from("order_tracking_submissions").insert({order_id: orderId,courier_id: courierId,tracking_ref: trackingRef,tracking_date: trackingDate,tracking_screenshot_url: trackingScreenshotUrl,note,submitted_by_operator_id: operator.id,is_final_delivery_yn: isFinalDelivery});
  if (error) redirect(`/importer/orders/${orderId}/operations?error=${encodeURIComponent(error.message)}`);

  if (isFinalDelivery) await supabase.from("orders").update({tracking_locked_at: new Date().toISOString()}).eq("id", orderId);
  revalidatePath(`/importer/orders/${orderId}/operations`);
  redirect(`/importer/orders/${orderId}/operations?success=Tracking+added`);
}
