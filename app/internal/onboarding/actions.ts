"use server";

import { randomBytes } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createAuthAdminClient } from "@/utils/supabase/admin";
import { createClient } from "@/utils/supabase/server";

function textValue(formData: FormData, key: string) {
  return String(formData.get(key) ?? "").trim();
}

function nullableText(formData: FormData, key: string) {
  const value = textValue(formData, key);
  return value.length ? value : null;
}

function nullableUuid(formData: FormData, key: string) {
  const value = textValue(formData, key);
  return value.length ? value : null;
}

async function rpcNoRedirect(name: string, args: Record<string, unknown>) {
  const supabase = await createClient();
  const { error } = await (supabase as any).rpc(name, args);
  if (error) {
    throw new Error(error.message);
  }
}

function finish(successMessage: string) {
  revalidatePath("/internal/onboarding");
  revalidatePath("/internal/access-control");
  redirect(`/internal/onboarding?saved=${encodeURIComponent(successMessage)}`);
}

async function callRpc(name: string, args: Record<string, unknown>, successMessage: string) {
  await rpcNoRedirect(name, args);
  finish(successMessage);
}

export async function upsertShipperBranchAction(formData: FormData) {
  await callRpc("internal_upsert_shipper_branch_v1", {
    p_shipper_id: nullableUuid(formData, "shipper_id"),
    p_name: textValue(formData, "name"),
    p_contact_email: nullableText(formData, "contact_email"),
    p_contact_phone: nullableText(formData, "contact_phone"),
    p_country_id: nullableUuid(formData, "country_id"),
    p_vat_treatment: nullableText(formData, "vat_treatment"),
    p_vat_registration_country: nullableText(formData, "vat_registration_country"),
  }, "Shipping-company branch saved");
}

export async function upsertImporterBranchAction(formData: FormData) {
  await callRpc("internal_upsert_importer_branch_v1", {
    p_importer_id: nullableUuid(formData, "importer_id"),
    p_shipper_id: nullableUuid(formData, "shipper_id"),
    p_country_id: nullableUuid(formData, "country_id"),
    p_company_name: textValue(formData, "company_name"),
    p_trading_name: nullableText(formData, "trading_name"),
    p_address: nullableText(formData, "address"),
  }, "Importer/customer branch saved");
}

export async function upsertImporterDeliveryProfileAction(formData: FormData) {
  await callRpc("internal_upsert_importer_delivery_profile_v1", {
    p_importer_id: nullableUuid(formData, "importer_id"),
    p_final_recipient_name: textValue(formData, "final_recipient_name"),
    p_final_recipient_address_line_1: textValue(formData, "final_recipient_address_line_1"),
    p_final_recipient_address_line_2: nullableText(formData, "final_recipient_address_line_2"),
    p_final_recipient_city: nullableText(formData, "final_recipient_city"),
    p_final_recipient_region: nullableText(formData, "final_recipient_region"),
    p_final_recipient_country: textValue(formData, "final_recipient_country"),
    p_final_recipient_phone: nullableText(formData, "final_recipient_phone"),
    p_final_recipient_email: nullableText(formData, "final_recipient_email"),
  }, "Importer/customer delivery profile saved");
}

export async function upsertExportEvidenceProfileAction(formData: FormData) {
  await callRpc("internal_upsert_export_evidence_profile_v1", {
    p_profile_id: nullableUuid(formData, "profile_id"),
    p_shipper_id: nullableUuid(formData, "shipper_id"),
    p_country_id: nullableUuid(formData, "country_id"),
    p_profile_name: nullableText(formData, "profile_name"),
    p_exporter_name: textValue(formData, "exporter_name"),
    p_exporter_address: textValue(formData, "exporter_address"),
    p_exporter_vat_number: nullableText(formData, "exporter_vat_number"),
    p_default_movement_consignee_name: textValue(formData, "default_movement_consignee_name"),
    p_default_movement_consignee_address: textValue(formData, "default_movement_consignee_address"),
    p_default_notify_party_name: nullableText(formData, "default_notify_party_name"),
    p_default_notify_party_address: nullableText(formData, "default_notify_party_address"),
  }, "Export evidence profile saved");
}

export async function setSupervisorScopeAction(formData: FormData) {
  const shipperIds = formData
    .getAll("shipper_ids")
    .map((value) => String(value).trim())
    .filter(Boolean);

  await callRpc("internal_set_supervisor_scope_v1", {
    p_supervisor_staff_id: nullableUuid(formData, "supervisor_staff_id"),
    p_scope_mode: textValue(formData, "scope_mode"),
    p_shipper_ids: shipperIds,
  }, "Supervisor scope saved");
}

export async function linkOperatorImporterAction(formData: FormData) {
  const roleCodes = formData
    .getAll("role_codes")
    .map((value) => String(value).trim())
    .filter((value): value is "customer" | "importer" => value === "customer" || value === "importer");

  if (roleCodes.length === 0) {
    throw new Error("Select at least one portal role");
  }

  await rpcNoRedirect("internal_set_operator_importer_roles_v1", {
    p_operator_id: nullableUuid(formData, "operator_id"),
    p_importer_id: nullableUuid(formData, "importer_id"),
    p_relationship_type: textValue(formData, "relationship_type"),
    p_role_codes: roleCodes,
  });

  finish(
    roleCodes.length === 2
      ? "Existing user roles saved as Customer + Importer"
      : roleCodes[0] === "customer"
        ? "Existing user roles saved as Customer only"
        : "Existing user roles saved as Importer only",
  );
}

export type NewOperatorOnboardingState = {
  status: "idle" | "success" | "error";
  message?: string;
  email?: string;
  temporaryPassword?: string;
};

export const initialNewOperatorOnboardingState: NewOperatorOnboardingState = {
  status: "idle",
};

function generateTemporaryPassword() {
  // 24 random bytes encoded as base64url gives a high-entropy, copyable temporary credential.
  return `${randomBytes(24).toString("base64url")}aA7!`;
}

export async function createNewOperatorOnboardingAction(
  _previousState: NewOperatorOnboardingState,
  formData: FormData,
): Promise<NewOperatorOnboardingState> {
  const email = textValue(formData, "email").toLowerCase();
  const fullName = textValue(formData, "full_name");
  const phone = nullableText(formData, "phone");
  const importerId = nullableUuid(formData, "importer_id");
  const relationshipType = textValue(formData, "relationship_type");
  const roleCodes = formData
    .getAll("role_codes")
    .map((value) => String(value).trim())
    .filter((value): value is "customer" | "importer" => value === "customer" || value === "importer");

  if (!email || !fullName || !importerId) {
    return { status: "error", message: "Name, email and importer/customer branch are required." };
  }

  if (roleCodes.length === 0) {
    return { status: "error", message: "Select at least one portal role." };
  }

  if (relationshipType !== "sole_owner" && relationshipType !== "authorised_user") {
    return { status: "error", message: "Select a valid relationship." };
  }

  const sessionClient = await createClient();
  const { data: { user } } = await sessionClient.auth.getUser();
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
      "internal_create_operator_onboarding_v1",
      {
        p_auth_user_id: created.user.id,
        p_email: email,
        p_full_name: fullName,
        p_phone: phone,
        p_importer_id: importerId,
        p_relationship_type: relationshipType,
        p_role_codes: roleCodes,
      },
    );

    if (platformError) {
      throw new Error(platformError.message);
    }
  } catch (error) {
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(created.user.id);

    if (deleteError) {
      // A failed deletion must still leave the login unusable. Replace the known
      // temporary credential with an undisclosed random credential and ban it.
      const undisclosedPassword = generateTemporaryPassword();
      const { error: disableError } = await adminClient.auth.admin.updateUserById(created.user.id, {
        password: undisclosedPassword,
        ban_duration: "876000h",
      });

      if (disableError) {
        return {
          status: "error",
          message: "Onboarding failed and automatic Auth compensation also failed. Treat this login as incomplete and escalate for immediate repair.",
        };
      }
    }

    return {
      status: "error",
      message: error instanceof Error ? error.message : "Onboarding failed. The new login was compensated and is not ready for use.",
    };
  }

  revalidatePath("/internal/onboarding");
  revalidatePath("/internal/access-control");

  return {
    status: "success",
    message: "New login created. Copy these details now; the temporary password is not stored by the platform.",
    email,
    temporaryPassword,
  };
}
