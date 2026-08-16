import { createClient } from "@/utils/supabase/server";

export type PlatformWorkspace =
  | "internal"
  | "shipper"
  | "customer"
  | "importer"
  | "workspace_select";

export type PlatformAccessMembership = {
  id: string;
  role_code:
    | "admin"
    | "supervisor"
    | "shipper_admin"
    | "shipper_operator"
    | "shipper_readonly"
    | "customer"
    | "importer";
  shipper_id: string | null;
  importer_id: string | null;
  staff_id: string | null;
  active: boolean;
  created_at: string;
  revoked_at: string | null;
};

export type PlatformAccessContext = {
  authenticated: boolean;
  auth_user_id: string | null;
  profile: Record<string, unknown> | null;
  memberships: PlatformAccessMembership[];
  operator_importer_ids: string[];
  has_internal_membership: boolean;
  has_shipper_membership: boolean;
  has_customer_membership: boolean;
  has_importer_membership: boolean;
  legacy_staff: boolean;
  legacy_shipper: boolean;
  legacy_operator: boolean;
  membership_workspace: PlatformWorkspace | null;
  legacy_workspace: "internal" | "shipper" | "importer" | null;
  resolved_workspace: PlatformWorkspace | null;
  resolution_source: "membership" | "legacy_fallback" | "none";
  must_change_password: boolean;
  profile_active: boolean;
};

export function workspacePath(workspace: PlatformWorkspace | null) {
  if (workspace === "internal") return "/internal";
  if (workspace === "shipper") return "/shipper";
  if (workspace === "customer") return "/customer";
  if (workspace === "importer") return "/importer";
  if (workspace === "workspace_select") return "/workspace/select";
  return null;
}

export function hasExplicitMembershipResolution(access: PlatformAccessContext) {
  return access.membership_workspace !== null;
}

export function canAccessPortal(
  access: PlatformAccessContext,
  portal: "customer" | "importer",
) {
  if (hasExplicitMembershipResolution(access)) {
    return portal === "customer"
      ? access.has_customer_membership === true
      : access.has_importer_membership === true;
  }

  // Patch F transition fallback: preserve the pre-enforcement operator path only
  // when no explicit membership workspace is available.
  return access.legacy_operator === true;
}

export async function resolveCurrentPlatformAccess(): Promise<PlatformAccessContext> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("current_platform_access_context_v1");

  if (error) {
    throw new Error(`Unable to resolve platform access: ${error.message}`);
  }

  return data as PlatformAccessContext;
}
