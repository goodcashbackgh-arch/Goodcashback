"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const PAGE_PATH = "/internal/completion-loyalty-rewards/supplier-wallet-payments";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function readSelectedIds(formData: FormData) {
  return formData
    .getAll("order_funding_event_id")
    .map((value) => String(value ?? "").trim())
    .filter(Boolean);
}

function redirectWithResult(params: Record<string, string>, path = PAGE_PATH): never {
  const query = new URLSearchParams(params);
  const separator = path.includes("?") ? "&" : "?";
  redirect(`${path}${separator}${query.toString()}`);
}

async function requireSignedInStaff() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) redirectWithResult({ error: error?.message || "Active staff access is required." });
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  return supabase;
}

type BatchRow = {
  row_status?: string | null;
  blocker?: string | null;
  batch_id?: string | null;
  batch_ref?: string | null;
  detail_href?: string | null;
};

export async function createCompletionLoyaltySupplierWalletBatchAction(formData: FormData) {
  const selectedIds = readSelectedIds(formData);
  const notes = readString(formData, "notes") || "Completion loyalty supplier wallet payment batch created from frontend.";

  if (selectedIds.length === 0) {
    redirectWithResult({ error: "Select at least one ready supplier wallet payment candidate." });
  }

  const supabase = await requireSignedInStaff();
  const { data, error } = await (supabase as any).rpc("staff_create_completion_loyalty_supplier_wallet_cash_batch_v1", {
    p_order_funding_event_ids: selectedIds,
    p_notes: notes,
  });

  if (error) redirectWithResult({ error: error.message });

  const rows = ((data ?? []) as BatchRow[]);
  const batched = rows.filter((row) => row.row_status === "batched_validated" && row.batch_id);
  const alreadyBatched = rows.filter((row) => row.row_status === "already_batched" && row.batch_id);
  const blocked = rows.filter((row) => row.row_status === "blocked" || row.blocker);
  const firstHref = batched[0]?.detail_href || alreadyBatched[0]?.detail_href || "";
  const firstBlocker = blocked.find((row) => row.blocker)?.blocker || "";

  revalidatePath(PAGE_PATH);
  revalidatePath("/internal/accounting-command-centre/cash-posting");

  if (firstHref && blocked.length === 0) {
    redirect(firstHref);
  }

  const batchRefs = Array.from(new Set(rows.map((row) => row.batch_ref).filter(Boolean))).join(", ");
  redirectWithResult({
    [blocked.length > 0 ? "error" : "success"]: blocked.length > 0
      ? `Supplier wallet batch blocked for ${blocked.length} row${blocked.length === 1 ? "" : "s"}${firstBlocker ? `: ${firstBlocker}` : ""}.`
      : `Supplier wallet batch ready${batchRefs ? `: ${batchRefs}` : ""}.`,
  });
}
