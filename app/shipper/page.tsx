import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export default async function ShipperPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) {
    redirect("/auth/check");
  }

  return (
    <main className="min-h-screen p-6">
      <h1 className="text-2xl font-semibold">Goodcashback Shipper</h1>
      <p>Shipper shell</p>
      <p>Welcome: {shipperUser.full_name}</p>
    </main>
  );
}
