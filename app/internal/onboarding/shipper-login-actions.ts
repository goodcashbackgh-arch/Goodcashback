"use server";

import { randomBytes } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createAuthAdminClient } from "@/utils/supabase/admin";
import { createClient } from "@/utils/supabase/server";

export type NewShipperOnboardingState = {
  status: "idle" | "success" | "error";
  message?: string;
  email?: string;
  temporaryPassword?: string;
};

function textValue(formData: FormData, key: string) {
  return String(formData.get(key) ?? "").trim();
}

function nullableText(formData: FormData, key: string) {
  const value = textValue(formData, key);
  return value.length ? value : null;
}

function generateTemporaryPassword() {
  return `${randomBytes(24).toString("base64url")}aA7!`;
}

export async function createNewShipperOnboardingAction(
  _previousState: NewShipperOnboardingState,
  formData: FormData,
): Promise<NewShipperOnboardingState> {
  const email = textValue(formData, "email").toLowerCase();
  const fullName = textValue(formData, "full_name");
  const phone = nullableText(formData, "phone");
  const shipperId = textValue(formData, "shipper_id");
  const roleCode = textValue(formData, "role_code");

  if (!email || !fullName || !shipperId) {
    return { status: "error", message: "Name, email and shipper branch are required." };
  }

  if (!["shipper_admin", "shipper_operator", "shipper_readonly"].includes(roleCode)) {
    return { status: "error", message: "Select a valid shipper access level." };
  }

  const sessionClient = await createClient();
  const {
    data: { user },
  } = await sessionClient.auth.getUser();

  if (!user) {
    return { status: "error", message: "Your staff session has expired. Sign in again." };
  }

  const { data: staff, error: staffError } = await sessionClient
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    return { status: "error", message: "Active staff access is required to create a login." };
  }

  const temporaryPassword = generateTemporaryPassword();
  const adminClient = createAuthAdminClient();

  const { data: created, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password: temporaryPassword,
    email_confirm: true,
    user_metadata: { full_name: fullName },
  });

  if (createError || !created.user) {
    return {
      status: "error",
      message: createError?.message ?? "The authentication login could not be created.",
    };
  }

  try {
    const { error: platformError } = await (sessionClient as any).rpc(
      "internal_create_shipper_user_onboarding_v1",
      {
        p_auth_user_id: created.user.id,
        p_email: email,
        p_full_name: fullName,
        p_phone: phone,
        p_shipper_id: shipperId,
        p_role_code: roleCode,
      },
    );

    if (platformError) {
      throw new Error(platformError.message);
    }
  } catch (error) {
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(created.user.id);

    if (deleteError) {
      const undisclosedPassword = generateTemporaryPassword();
      const { error: disableError } = await adminClient.auth.admin.updateUserById(created.user.id, {
        password: undisclosedPassword,
        ban_duration: "876000h",
      });

      if (disableError) {
        return {
          status: "error",
          message: "Shipper onboarding failed and automatic Auth compensation also failed. Treat this login as incomplete and escalate for immediate repair.",
        };
      }
    }

    return {
      status: "error",
      message: error instanceof Error
        ? error.message
        : "Shipper onboarding failed. The new login was compensated and is not ready for use.",
    };
  }

  revalidatePath("/internal/onboarding");
  revalidatePath("/internal/access-control");

  return {
    status: "success",
    message: "New shipper login created. Copy these details now; the temporary password is not stored by the platform.",
    email,
    temporaryPassword,
  };
}
