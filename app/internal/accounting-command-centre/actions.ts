"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type FreezeResult = {
  snapshot_id?: string | null;
  sales_invoice_id?: string | null;
  freeze_status?: string | null;
  blocker?: string | null;
};

function asStringArray(value: FormDataEntryValue[]) {
  return value.map((entry) => String(entry ?? "").trim()).filter(Boolean);
}

function hasAccountingAdminTesting(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Record<string, unknown>;
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

export async function freezeSelectedCustomerSalesRowsAction(formData: FormData) {
  const selectedIds = asStringArray(formData.getAll("sales_invoice_id"));

  if (selectedIds.length === 0) {
    redirect("/internal/accounting-command-centre?error=Select at least one customer sales row to freeze");
  }

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

  const canAccess = String(staff.role_type ?? "") === "admin" || hasAccountingAdminTesting((staff as Record<string, unknown>).permissions_json);
  if (!canAccess) {
    redirect("/internal/accounting-command-centre?error=Accounting admin access required");
  }

  const { data, error } = await (supabase as any).rpc("internal_freeze_customer_sales_sage_batch_v1", {
    p_sales_invoice_ids: selectedIds,
    p_notes: "Accounting command centre batch freeze",
  });

  if (error) {
    redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(error.message)}`);
  }

  const rows = ((data ?? []) as FreezeResult[]);
  const frozenSnapshotIds = rows
    .filter((row) => row.freeze_status === "frozen" && row.snapshot_id)
    .map((row) => row.snapshot_id as string);
  const blockedCount = rows.filter((row) => row.freeze_status !== "frozen").length;

  if (frozenSnapshotIds.length > 0) {
    const { error: revalidateError } = await (supabase as any).rpc("internal_revalidate_sage_posting_snapshots_v1", {
      p_snapshot_ids: frozenSnapshotIds,
    });

    if (revalidateError) {
      redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(`Frozen but revalidation failed: ${revalidateError.message}`)}`);
    }
  }

  revalidatePath("/internal/accounting-command-centre");
  revalidatePath("/internal/sage-ready");

  const message = blockedCount > 0
    ? `Frozen ${frozenSnapshotIds.length} row(s); ${blockedCount} row(s) not frozen`
    : `Frozen and revalidated ${frozenSnapshotIds.length} row(s)`;

  redirect(`/internal/accounting-command-centre?success=${encodeURIComponent(message)}`);
}
