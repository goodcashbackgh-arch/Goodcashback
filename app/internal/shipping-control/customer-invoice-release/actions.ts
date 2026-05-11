"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export async function createCustomerInvoiceDrafts(formData: FormData) {
  const rawIds = formData.getAll("shipment_batch_id").map((value) => String(value)).filter(Boolean);
  if (rawIds.length === 0) {
    redirect("/internal/shipping-control/customer-invoice-release?result=no_ready_rows_selected");
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data, error } = await (supabase as any).rpc("internal_customer_invoice_release_create_drafts_v1", {
    p_shipment_batch_ids: rawIds,
  });

  if (error) {
    redirect(`/internal/shipping-control/customer-invoice-release?result=error&message=${encodeURIComponent(error.message)}`);
  }

  const rows = (data ?? []) as Array<{ result_status?: string | null }>;
  const created = rows.filter((row) => row.result_status === "draft_created").length;
  const skipped = rows.length - created;

  revalidatePath("/internal/shipping-control/customer-invoice-release");
  revalidatePath("/internal/shipping-control");
  redirect(`/internal/shipping-control/customer-invoice-release?result=created&created=${created}&skipped=${skipped}`);
}
