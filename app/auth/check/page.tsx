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
