"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { postSupplierCreditNoteBatchToSage } from "@/lib/sage/supplierCreditNotePostingWithFrozenMappings";
import { afterSupplierCreditNotePost } from "@/lib/sage/supplierCreditNotePostAftercare";

type StaffRow = { id: string; role_type: string | null; permissions_json: unknown };

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
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

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(error?.message || "Active staff account required")}`);
  const row = staff as StaffRow;
  const allowed = String(row.role_type ?? "") === "admin" || hasAccountingAdminTesting(row.permissions_json);
  if (!allowed) redirect("/internal/accounting-command-centre?error=Accounting admin access required");
  return { staffId: row.id };
}

export async function postSupplierCreditNoteBatchToSageWithAftercareAction(formData: FormData) {
  const batchId = String(formData.get("batch_id") ?? "").trim();
  if (!batchId) redirect("/internal/accounting-command-centre?error=Missing posting batch id");

  const { staffId } = await requireAccountingPostingContext();
  const origin = appOrigin();
  let redirectTo = `/internal/accounting-command-centre/batches/${batchId}`;

  try {
    const result = await postSupplierCreditNoteBatchToSage({ batchId, staffId, origin });

    if (result.failed > 0) {
      redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(`Supplier credit note Sage posting finished with failures: ${result.posted} posted, ${result.failed} failed, ${result.total} total. Check the row Reason / error column.`)}`;
    } else {
      try {
        const aftercare = await afterSupplierCreditNotePost({ batchId, staffId, origin });
        const summary = `Supplier credit note Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.total} total. Endpoint /purchase_credit_notes. Aftercare restored ${aftercare.restored} row payload(s), attached ${aftercare.attached} file(s), skipped ${aftercare.skipped}, failed ${aftercare.failed}.`;
        redirectTo = aftercare.failed > 0
          ? `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(`${summary} ${aftercare.errors.join(" | ")}`)}`
          : `/internal/accounting-command-centre/batches/${batchId}?success=${encodeURIComponent(summary)}`;
      } catch (error) {
        const message = error instanceof Error ? error.message : "Supplier credit note aftercare failed.";
        redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(`Supplier credit note posted, but post-success aftercare failed: ${message}`)}`;
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Supplier credit note Sage posting failed.";
    redirectTo = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(message)}`;
  }

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);
  redirect(redirectTo);
}
