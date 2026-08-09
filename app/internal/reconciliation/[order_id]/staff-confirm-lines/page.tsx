import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const retiredStatuses = new Set(["rejected_resubmit_required", "duplicate_blocked", "superseded"]);

export default async function Page({ params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: order } = await supabase
    .from("orders")
    .select("id")
    .eq("id", orderId)
    .maybeSingle();
  if (!order) redirect("/internal/supplier-draft-ready?error=Order+not+found");

  const { data: invoices } = await supabase
    .from("supplier_invoices")
    .select("id, review_status, uploaded_at")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: true });

  const activeInvoices = (invoices ?? []).filter((invoice) => !retiredStatuses.has(String(invoice.review_status ?? "pending_review")));

  if (activeInvoices.length === 0) {
    redirect(`/internal/reconciliation/${orderId}?error=No+active+supplier+invoice+available+for+staff+confirmation`);
  }

  if (activeInvoices.length === 1) {
    redirect(`/internal/reconciliation/${orderId}/invoice-bundle/${activeInvoices[0].id}`);
  }

  redirect(`/internal/reconciliation/${orderId}/invoice-bundle`);
}
