"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { postSupplierCreditNoteBatchToSage } from "@/lib/sage/supplierCreditNotePostingWithFrozenMappings";
import { attachSupplierCreditNoteSourcePdfToSage } from "@/lib/sage/supplierCreditNoteAttachment";

type Row = Record<string, unknown>;
function text(v: unknown) { return typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : ""; }
function allowed(p: unknown) { return !!p && typeof p === "object" && !Array.isArray(p) && ((p as Row).accounting_admin_testing === true || (p as Row).admin_testing === true); }
function origin() { const v = process.env.NEXT_PUBLIC_APP_URL?.trim() || process.env.NEXT_PUBLIC_SITE_URL?.trim() || process.env.SITE_URL?.trim(); return v ? v.replace(/\/$/, "") : process.env.VERCEL_URL?.trim() ? `https://${process.env.VERCEL_URL.trim()}` : "https://goodcashback-v2.vercel.app"; }

async function staffId() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff, error } = await supabase.from("staff").select("id, role_type, permissions_json").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (error || !staff) redirect(`/internal/accounting-command-centre?error=${encodeURIComponent(error?.message || "Active staff account required")}`);
  if (text((staff as Row).role_type) !== "admin" && !allowed((staff as Row).permissions_json)) redirect("/internal/accounting-command-centre?error=Accounting admin access required");
  return text((staff as Row).id);
}

async function snapshotIds(batchId: string) {
  const { data, error } = await supabaseAdmin.from("sage_posting_batch_rows").select("snapshot_id").eq("batch_id", batchId).eq("document_lane", "supplier_credit_note").eq("posting_status", "posted");
  if (error) throw new Error(error.message);
  const ids = Array.from(new Set(((data ?? []) as Array<{ snapshot_id: string | null }>).map((r) => text(r.snapshot_id)).filter(Boolean)));
  if (!ids.length) return [];
  const { data: snapshots, error: se } = await supabaseAdmin.from("sage_posting_snapshots").select("id, sage_attachment_status").in("id", ids).eq("document_lane", "supplier_credit_note").eq("sage_posting_status", "posted");
  if (se) throw new Error(se.message);
  return ((snapshots ?? []) as Array<{ id: string; sage_attachment_status: string | null }>).filter((s) => text(s.sage_attachment_status) !== "attached").map((s) => s.id);
}

async function attachPosted(batchId: string, sid: string, org: string) {
  const ids = await snapshotIds(batchId);
  const out = { attempted: ids.length, attached: 0, skipped: 0, failed: 0, errors: [] as string[] };
  for (const id of ids) {
    try {
      const r = await attachSupplierCreditNoteSourcePdfToSage({ snapshotId: id, staffId: sid, origin: org });
      out.attached += r.attached;
      out.skipped += r.skipped ?? 0;
    } catch (e) {
      out.failed += 1;
      out.errors.push(e instanceof Error ? e.message : "Supplier credit note PDF attachment failed.");
    }
  }
  return out;
}

export async function postSupplierCreditNoteBatchToSageV2Action(formData: FormData) {
  const batchId = text(formData.get("batch_id"));
  if (!batchId) redirect("/internal/accounting-command-centre?error=Missing posting batch id");
  const sid = await staffId();
  const org = origin();
  let to = `/internal/accounting-command-centre/batches/${batchId}`;
  try {
    const result = await postSupplierCreditNoteBatchToSage({ batchId, staffId: sid, origin: org });
    let msg = `Supplier credit note Sage posting finished: ${result.posted} posted, ${result.failed} failed, ${result.total} total. Endpoint /purchase_credit_notes. Restored ${(result as Row).restoredPayloadRows ?? 0} frozen row payload(s).`;
    let attachment = undefined as Awaited<ReturnType<typeof attachPosted>> | undefined;
    if (result.posted > 0) {
      attachment = await attachPosted(batchId, sid, org);
      msg += ` Source PDF attachment: ${attachment.attached} attached, ${attachment.failed} failed, ${attachment.attempted} attempted.`;
      if (attachment.failed && attachment.errors[0]) msg += ` First attachment error: ${attachment.errors[0]}`;
    }
    const isError = result.failed > 0 || (attachment?.failed ?? 0) > 0;
    to = `/internal/accounting-command-centre/batches/${batchId}?${isError ? "error" : "success"}=${encodeURIComponent(msg)}`;
  } catch (e) {
    to = `/internal/accounting-command-centre/batches/${batchId}?error=${encodeURIComponent(e instanceof Error ? e.message : "Supplier credit note Sage posting failed.")}`;
  }
  revalidatePath("/internal/accounting-command-centre");
  revalidatePath(`/internal/accounting-command-centre/batches/${batchId}`);
  redirect(to);
}
