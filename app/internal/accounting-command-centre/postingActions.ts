"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { postCustomerSalesBatchToSage } from "@/lib/sage/posting";

type StaffRow = {
  id: string;
  role_type: string | null;
  permissions_json: unknown;
};

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

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

async function requireAccountingPostingContext() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(staffError?.message || "Active staff account required")}`);
  }

  const row = staff as StaffRow;
  const canAccess = String(row.role_type ?? "") === "admin" || hasAccountingAdminTesting(row.permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre?error=Accounting admin access required");

  return { staffId: row.id };
}

export async function postCustomerSalesBatchToSageAction(formData: FormData) {
  const batchId = formText(formData, "batch_id", "");
  if (!batchId) redirect("/internal/accounting-command-centre?error=Missing posting batch id");

  const { staffId } = await requireAccountingPostingContext();
  let redirectTo = `/internal/accounting-command-centre/batches/${batchId}`;

  try {
    const result = await postCustomerSalesBatchToSage({
      batchId,
      staffId,
      origin: appOrigin(),
    });

    if (result.failed > 0) {
      redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(`Customer sales Sage posting finished with failures: ${result.posted} posted, ${result.failed} failed, ${result.total} total. Check the row Reason / error column.`)}`;
    } else {
      redirectTo = `/internal/accounting-command-centre/batches/${batchId}?success=${encodeURIComponent(`Customer sales Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.total} total.`)}`;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Customer sales Sage posting failed.";
    redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(message)}`;
  }

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);
  redirect(redirectTo);
}
