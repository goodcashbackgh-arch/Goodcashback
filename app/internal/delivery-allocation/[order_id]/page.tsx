import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import DeliveryAllocationWorkspace from "../../../delivery-allocation/DeliveryAllocationWorkspace";
import { loadDeliveryAllocationData } from "../../../delivery-allocation/data";

export default async function InternalDeliveryAllocationPage({
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

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    redirect("/auth/check");
  }

  const { data, error } = await loadDeliveryAllocationData(supabase, orderId);
  if (error || !data) {
    redirect(`/internal/reconciliation/${orderId}?error=${encodeURIComponent(error ?? "Delivery allocation data not found.")}`);
  }

  return (
    <DeliveryAllocationWorkspace
      mode="staff"
      data={data}
      success={queryParams.success}
      error={queryParams.error}
    />
  );
}
