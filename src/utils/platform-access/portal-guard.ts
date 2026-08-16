import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  canAccessPortal,
  resolveCurrentPlatformAccess,
  workspacePath,
  type PlatformAccessContext,
} from "@/utils/platform-access/server";

export async function requirePortalAccess(
  portal: "customer" | "importer",
): Promise<PlatformAccessContext | null> {
  let access: PlatformAccessContext | null = null;

  try {
    access = await resolveCurrentPlatformAccess();
  } catch {
    // Resolver rollback path is intentionally handled below.
  }

  if (access) {
    if (!access.authenticated) {
      redirect("/login");
    }

    if (access.must_change_password === true) {
      redirect("/auth/change-password");
    }

    if (canAccessPortal(access, portal)) {
      return access;
    }

    const resolvedPath = workspacePath(access.resolved_workspace);
    if (resolvedPath) {
      redirect(resolvedPath);
    }

    redirect("/auth/check");
  }

  // Patch F acceptance fallback: if the resolver itself is unavailable,
  // preserve the pre-enforcement active-operator access path. This can be
  // removed only by Patch G after regression acceptance.
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirect("/auth/check");
  }

  return null;
}
