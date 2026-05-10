import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import DeliveryAllocationWorkspace from "../../../delivery-allocation/DeliveryAllocationWorkspace";
import { loadDeliveryAllocationData } from "../../../delivery-allocation/data";

export default async function ImporterDeliveryAllocationPage({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { order_id: orderId } = await params;
  const queryParams = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

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
    .select("id, importer_id")
    .eq("id", orderId)
    .maybeSingle();

  if (!order) redirect("/importer");

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (!access) redirect("/importer");

  const { data, error } = await loadDeliveryAllocationData(supabase, orderId);
  if (error || !data) {
    redirect(`/importer/reconciliation/${orderId}?error=${encodeURIComponent(error ?? "Delivery allocation data not found.")}`);
  }

  return (
    <DeliveryAllocationWorkspace
      mode="operator"
      data={data}
      success={queryParams.success}
      error={queryParams.error}
    />
  );
}
