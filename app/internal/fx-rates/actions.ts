"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithFxResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/fx-rates?${query.toString()}`);
}

function positiveNumber(raw: string, fieldName: string) {
  if (!raw) {
    throw new Error(`${fieldName} is required.`);
  }
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${fieldName} must be greater than zero.`);
  }
  return value;
}

function requiredNonNegativeNumber(raw: string, fieldName: string) {
  if (!raw) {
    throw new Error(`${fieldName} is required. Enter 0 if none applies.`);
  }
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${fieldName} cannot be negative.`);
  }
  return value;
}

export async function upsertFxRateAction(formData: FormData) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithFxResult({ fx_error: "Please sign in again before saving FX rates." });
  }

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirectWithFxResult({ fx_error: "Active staff user not found." });
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    redirectWithFxResult({ fx_error: "Only admin or supervisor staff can maintain FX rates." });
  }

  const countryId = readString(formData, "country_id");
  const rateDate = readString(formData, "rate_date");
  const quoteRateRaw = readString(formData, "quote_rate");
  const quoteMarkupRaw = readString(formData, "quote_card_markup_pct");
  const settlementRateRaw = readString(formData, "settlement_rate");
  const settlementMarkupRaw = readString(formData, "settlement_card_markup_pct");

  if (!countryId) {
    redirectWithFxResult({ fx_error: "Country is required." });
  }

  if (!/^\d{4}-\d{2}-\d{2}$/.test(rateDate)) {
    redirectWithFxResult({ fx_error: "Rate date is required." });
  }

  let quoteRate: number;
  let quoteMarkup: number;
  let settlementRate: number;
  let settlementMarkup: number;

  try {
    quoteRate = positiveNumber(quoteRateRaw, "Quote rate");
    quoteMarkup = requiredNonNegativeNumber(quoteMarkupRaw, "Quote card markup");
    settlementRate = positiveNumber(settlementRateRaw, "Settlement/base rate");
    settlementMarkup = requiredNonNegativeNumber(settlementMarkupRaw, "Settlement card markup");
  } catch (error) {
    redirectWithFxResult({ fx_error: error instanceof Error ? error.message : "Invalid FX input." });
  }

  const { error } = await supabase.rpc("staff_upsert_fx_rate_v1", {
    p_country_id: countryId,
    p_rate_date: rateDate,
    p_quote_rate: quoteRate,
    p_quote_card_markup_pct: quoteMarkup,
    p_settlement_rate: settlementRate,
    p_settlement_card_markup_pct: settlementMarkup,
  });

  if (error) {
    redirectWithFxResult({ fx_error: error.message });
  }

  revalidatePath("/internal/fx-rates");
  revalidatePath("/internal/dva-statement-import");

  redirectWithFxResult({
    country_id: countryId,
    from: readString(formData, "from"),
    to: readString(formData, "to"),
    fx_success: `Saved FX rate for ${rateDate}.`,
  });
}
