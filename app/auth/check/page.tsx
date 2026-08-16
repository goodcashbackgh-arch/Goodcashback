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

  // Patch C priority gate only. Read through the existing SECURITY DEFINER
  // shared resolver so platform_user_profiles RLS cannot hide the flag.
  // Existing portal routing below remains unchanged until Patch F.
  const { data: accessContext } = await supabase.rpc(
    "current_platform_access_context_v1",
  );

  if (accessContext?.must_change_password === true) {
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
