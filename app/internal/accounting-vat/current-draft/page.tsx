import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

const allowedTabs = new Set(["summary", "source", "box6", "box1", "purchases", "journals", "submission"]);
const activeStatuses = ["draft", "calculated", "admin_review_required", "blocked", "admin_approved", "sage_adjustment_journals_pending", "sage_adjustment_journals_posted", "sage_return_review_required", "sage_return_submitted", "mismatch_needs_admin_review", "reopened_for_correction"];

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function first(value: unknown): string {
  return Array.isArray(value) ? text(value[0]) : text(value);
}

export default async function CurrentVatDraftRedirectPage({ searchParams }: any = {}) {
  const queryParams = searchParams ? await searchParams : {};
  const requestedTab = first(queryParams?.tab);
  const tabSuffix = allowedTabs.has(requestedTab) ? `?tab=${encodeURIComponent(requestedTab)}` : "";

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data: run } = await db
    .from("vat_return_runs")
    .select("id")
    .in("status", activeStatuses)
    .order("period_start_date", { ascending: true })
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  const runId = text((run as Row | null)?.id);
  if (!runId) redirect("/internal/accounting-vat?vatError=No%20open%20VAT%20draft%20or%20review%20run%20found");
  redirect(`/internal/accounting-vat/returns/${runId}${tabSuffix}`);
}
