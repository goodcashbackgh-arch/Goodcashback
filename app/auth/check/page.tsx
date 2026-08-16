import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export default async function AuthCheckPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const userId = user.id;

  // Patch C priority gate only. Existing portal routing below remains unchanged
  // until the shared resolver is switched on in Patch F.
  const { data: profile } = await supabase
    .from("platform_user_profiles")
    .select("must_change_password")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  if (profile?.must_change_password === true) {
    redirect("/auth/change-password");
  }

  const { data: staff } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  if (staff) {
    redirect("/internal");
  }

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  if (shipperUser) {
    redirect("/shipper");
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  if (operator) {
    redirect("/importer");
  }

  redirect("/login");
}
