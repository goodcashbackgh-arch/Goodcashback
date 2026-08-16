import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  resolveCurrentPlatformAccess,
  workspacePath,
} from "@/utils/platform-access/server";

export default async function AuthCheckPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  try {
    const access = await resolveCurrentPlatformAccess();

    if (access.must_change_password === true) {
      redirect("/auth/change-password");
    }

    const resolvedPath = workspacePath(access.resolved_workspace);
    if (resolvedPath) {
      redirect(resolvedPath);
    }
  } catch {
    // Patch F transition fallback only: preserve the exact legacy route order
    // while membership routing is under acceptance testing.
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
