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

  return { supabase, staffId: String((staff as any).id) };
}

function journalRedirect(
  journalId: string,
  returnRunId: string,
  message: string,
  kind: "success" | "error",
) {
  if (returnRunId) {
    const vatParam = kind === "success" ? "vatSuccess" : "vatError";
    redirect(
      `/internal/accounting-vat/returns/${returnRunId}?tab=journals&${vatParam}=${encodeURIComponent(message)}`,
    );
  }

  redirect(`/internal/accounting-vat/journals/${journalId}?${kind}=${encodeURIComponent(message)}`);
}

export async function dryRunVatAdjustmentJournalAction(formData: FormData) {
  const journalId = formText(formData, "journal_id");
  const returnRunId = formText(formData, "return_run_id");
  if (!journalId) {
    if (returnRunId) {
      redirect(
        `/internal/accounting-vat/returns/${returnRunId}?tab=journals&vatError=${encodeURIComponent("Missing VAT adjustment journal id")}`,
      );
    }
    redirect(`/internal/accounting-vat?error=${encodeURIComponent("Missing VAT adjustment journal id")}`);
  }

  const { supabase } = await requireVatPostingAdmin();
  const { data, error } = await (supabase as any).rpc("staff_validate_vat_adjustment_journal_dry_run_v1", {
    p_vat_return_adjustment_journal_id: journalId,
  });

  revalidatePath("/internal/accounting-vat");
  if (returnRunId) revalidatePath(`/internal/accounting-vat/returns/${returnRunId}`);
  revalidatePath(`/internal/accounting-vat/journals/${journalId}`);

  if (error) {
    journalRedirect(
      journalId,
      returnRunId,
      error.message || "VAT journal dry-run validation failed.",
      "error",
    );
  }
  const valid = Boolean((data as any)?.valid);
  const status = String((data as any)?.status ?? "dry-run complete");
  journalRedirect(
    journalId,
    returnRunId,
    valid
      ? `Dry-run validated: ${status}`
      : `Dry-run completed with issues: ${status}`,
    valid ? "success" : "error",
  );
}

export async function approveVatAdjustmentJournalAction(formData: FormData) {
  const journalId = formText(formData, "journal_id");
  const formReturnRunId = formText(formData, "return_run_id");
  if (!journalId) {
    if (formReturnRunId) {
      redirect(
        `/internal/accounting-vat/returns/${formReturnRunId}?tab=journals&vatError=${encodeURIComponent("Missing VAT adjustment journal id")}`,
      );
    }
    redirect(`/internal/accounting-vat?error=${encodeURIComponent("Missing VAT adjustment journal id")}`);
  }

  const { supabase } = await requireVatPostingAdmin();
  const { data, error } = await (supabase as any).rpc("staff_approve_vat_adjustment_journal_v1", {
    p_vat_return_adjustment_journal_id: journalId,
  });

  const rpcReturnRunId = String((data as any)?.vat_return_run_id ?? "");
  const returnRunId = formReturnRunId || rpcReturnRunId;
  revalidatePath("/internal/accounting-vat");
  if (returnRunId) revalidatePath(`/internal/accounting-vat/returns/${returnRunId}`);
  revalidatePath(`/internal/accounting-vat/journals/${journalId}`);

  if (error) {
    journalRedirect(
      journalId,
      formReturnRunId,
      error.message || "VAT journal admin approval failed.",
      "error",
    );
  }
  journalRedirect(
    journalId,
    formReturnRunId,
    "VAT adjustment journal admin approved.",
    "success",
  );
}

export async function postVatAdjustmentJournalToSageAction(formData: FormData) {
  const journalId = formText(formData, "journal_id");
  const returnRunId = formText(formData, "return_run_id");
  const confirmLivePost = formText(formData, "confirm_live_sage_post");
  const redirectBase = journalId
    ? `/internal/accounting-vat/journals/${journalId}`
    : "/internal/accounting-vat";

  if (!journalId) {
    if (returnRunId) {
      redirect(
        `/internal/accounting-vat/returns/${returnRunId}?tab=journals&vatError=${encodeURIComponent("Missing VAT adjustment journal id")}`,
      );
    }
    redirect(`/internal/accounting-vat?error=${encodeURIComponent("Missing VAT adjustment journal id")}`);
  }
  if (confirmLivePost !== "yes") {
    journalRedirect(
      journalId,
      returnRunId,
      "Confirm controlled live accounting posting before posting this VAT adjustment journal.",
      "error",
    );
  }

  const { staffId } = await requireVatPostingAdmin();
  let redirectTo = redirectBase;

  try {
    const result = await postVatAdjustmentJournalToSage({
      journalId,
      staffId,
      origin: appOrigin(),
    });

    if (result.failed > 0) {
      const message = result.error || "VAT journal accounting posting failed";
      redirectTo = returnRunId
        ? `/internal/accounting-vat/returns/${returnRunId}?tab=journals&vatError=${encodeURIComponent(message)}`
        : `${redirectBase}?error=${encodeURIComponent(message)}`;
    } else {
      const message = `VAT adjustment journal posted to accounting system: ${result.sageReference || result.sageJournalId}`;
      redirectTo = returnRunId
        ? `/internal/accounting-vat/returns/${returnRunId}?tab=journals&vatSuccess=${encodeURIComponent(message)}`
        : `${redirectBase}?success=${encodeURIComponent(message)}`;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "VAT adjustment journal accounting posting failed.";
    redirectTo = returnRunId
      ? `/internal/accounting-vat/returns/${returnRunId}?tab=journals&vatError=${encodeURIComponent(message)}`
      : `${redirectBase}?error=${encodeURIComponent(message)}`;
  }

  revalidatePath("/internal/accounting-vat");
  if (returnRunId) revalidatePath(`/internal/accounting-vat/returns/${returnRunId}`);
  revalidatePath(`/internal/accounting-vat/journals/${journalId}`);
  redirect(redirectTo);
}
