"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { postVatAdjustmentJournalToSage } from "@/lib/sage/vatAdjustmentJournalPosting";

function formText(formData: FormData, key: string, fallback = "") {
  return String(formData.get(key) ?? fallback).trim();
}

function appOrigin() {
  const configured = process.env.NEXT_PUBLIC_APP_URL?.trim()
    || process.env.NEXT_PUBLIC_SITE_URL?.trim()
    || process.env.SITE_URL?.trim();
  if (configured) return configured.replace(/\/$/, "");
  if (process.env.VERCEL_URL?.trim()) return `https://${process.env.VERCEL_URL.trim()}`;
  return "https://goodcashback-v2.vercel.app";
}

async function requireVatPostingAdmin() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) redirect(`/internal/accounting-vat?error=${encodeURIComponent(error?.message || "Active staff account required")}`);
  if (String((staff as any).role_type ?? "") !== "admin") redirect("/internal/accounting-vat?error=Admin access required for VAT journal posting");

  return { staffId: String((staff as any).id) };
}

export async function postVatAdjustmentJournalToSageAction(formData: FormData) {
  const journalId = formText(formData, "journal_id");
  const returnRunId = formText(formData, "return_run_id");
  const redirectBase = journalId
    ? `/internal/accounting-vat/journals/${journalId}`
    : "/internal/accounting-vat";

  if (!journalId) redirect(`/internal/accounting-vat?error=${encodeURIComponent("Missing VAT adjustment journal id")}`);

  const { staffId } = await requireVatPostingAdmin();
  let redirectTo = redirectBase;

  try {
    const result = await postVatAdjustmentJournalToSage({
      journalId,
      staffId,
      origin: appOrigin(),
    });

    if (result.failed > 0) {
      redirectTo = `${redirectBase}?error=${encodeURIComponent(result.error || "VAT journal Sage posting failed")}`;
    } else {
      redirectTo = `${redirectBase}?success=${encodeURIComponent(`VAT adjustment journal posted to Sage: ${result.sageReference || result.sageJournalId}`)}`;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "VAT adjustment journal Sage posting failed.";
    redirectTo = `${redirectBase}?error=${encodeURIComponent(message)}`;
  }

  revalidatePath("/internal/accounting-vat");
  if (returnRunId) revalidatePath(`/internal/accounting-vat/returns/${returnRunId}`);
  revalidatePath(`/internal/accounting-vat/journals/${journalId}`);
  redirect(redirectTo);
}
