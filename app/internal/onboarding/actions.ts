"use server";

import { revalidatePath } from "next/cache";
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

async function callRpc(name: string, args: Record<string, unknown>) {
  const supabase = await createClient();
  const { error } = await (supabase as any).rpc(name, args);
  if (error) {
    throw new Error(error.message);
  }
  revalidatePath("/internal/onboarding");
  revalidatePath("/internal/access-control");
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
  });
}

export async function upsertImporterBranchAction(formData: FormData) {
  await callRpc("internal_upsert_importer_branch_v1", {
    p_importer_id: nullableUuid(formData, "importer_id"),
    p_shipper_id: nullableUuid(formData, "shipper_id"),
    p_country_id: nullableUuid(formData, "country_id"),
    p_company_name: textValue(formData, "company_name"),
    p_trading_name: nullableText(formData, "trading_name"),
    p_address: nullableText(formData, "address"),
  });
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
  });
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
  });
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
  });
}

export async function linkOperatorImporterAction(formData: FormData) {
  await callRpc("internal_link_operator_importer_v1", {
    p_operator_id: nullableUuid(formData, "operator_id"),
    p_importer_id: nullableUuid(formData, "importer_id"),
    p_relationship_type: textValue(formData, "relationship_type"),
    p_role_code: textValue(formData, "role_code"),
  });
}
