"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

function clean(value: FormDataEntryValue | null) {
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithError(message: string) {
  redirect(`/internal/accounting-vat?tab=runs&vatError=${encodeURIComponent(message)}`);
}

export async function generateVatDraftRunAction(formData: FormData) {
  const periodStart = clean(formData.get("period_start_date"));
  const periodEnd = clean(formData.get("period_end_date"));
  const periodLabel = clean(formData.get("return_period_label"));

  if (!periodStart || !periodEnd) {
    redirectWithError("VAT period start and end dates are required.");
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type, active")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff || staff.role_type !== "admin") {
    redirectWithError("Admin-only VAT Return Workbench access required.");
  }

  const { data, error } = await supabase.rpc("generate_vat_return_draft_run_v1", {
    p_period_start_date: periodStart,
    p_period_end_date: periodEnd,
    p_return_period_label: periodLabel || null,
  });

  if (error) {
    redirectWithError(error.message || "VAT draft run generation failed.");
  }

  const result = data as { vat_return_run_id?: string } | null;
  const runId = result?.vat_return_run_id;

  revalidatePath("/internal/accounting-vat");
  redirect(`/internal/accounting-vat?tab=runs&vatGenerated=${encodeURIComponent(runId ?? "1")}`);
}
