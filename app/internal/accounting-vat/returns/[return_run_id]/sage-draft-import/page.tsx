import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import SageVatUploadForm from "./SageVatUploadForm";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
type UploadPurpose = "draft_reconciliation" | "final_submission_evidence";

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function cleanDisplay(value: unknown): string {
  return text(value)
    .replaceAll("([object Object])", "")
    .replaceAll("[object Object]", "")
    .replace(/\s+—\s*$/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function num(value: unknown): number | null {
  const raw = text(value);
  if (!raw) return null;
  const parsed = Number(raw.replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function date(value: unknown): string {
  const raw = cleanDisplay(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed);
}

function label(value: unknown, max = 80): string {
  const raw = cleanDisplay(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function queryFirst(value: unknown): string {
  return Array.isArray(value) ? text(value[0]) : text(value);
}

function purposeFrom(value: unknown): UploadPurpose | null {
  const raw = queryFirst(value);
  if (raw === "draft_reconciliation" || raw === "final_submission_evidence") return raw;
  return null;
}

function datetimeLocalNow(): string {
  return new Date().toISOString().slice(0, 16);
}

function platformMatchesRecon(run: Row, recon: Row): boolean {
  if (!text(recon.id)) return false;
  return [1, 2, 3, 4, 5, 6, 7, 8, 9].every((box) => Math.abs((num(run[`expected_box${box}_gbp`]) ?? 0) - (num(recon[`box${box}_gbp`]) ?? 0)) <= 0.005);
}

const BOXES = [
  { box: 1, label: "VAT due on sales/outputs" },
  { box: 2, label: "VAT due on acquisitions", optional: true },
  { box: 3, label: "Total VAT due", optional: true },
  { box: 4, label: "VAT reclaimed on purchases/inputs" },
  { box: 5, label: "Net VAT to pay/reclaim", optional: true },
  { box: 6, label: "Net sales/outputs" },
  { box: 7, label: "Net purchases/inputs" },
  { box: 8, label: "EU dispatches", optional: true },
  { box: 9, label: "EU acquisitions", optional: true },
];

export default async function SageVatUploadPage({ params, searchParams }: any) {
  const routeParams = params ? await params : {};
  const queryParams = searchParams ? await searchParams : {};
  const runId = text(routeParams?.return_run_id);
  const vatError = queryFirst(queryParams?.vatError);
  const showPreview = queryFirst(queryParams?.preview) === "1";
  const missingBoxes = queryFirst(queryParams?.missing).split(",").map((item) => item.trim()).filter(Boolean);
  const fileName = queryFirst(queryParams?.file_name);
  const selectedPurpose = purposeFrom(queryParams?.upload_purpose);
  const sageReturnReference = queryFirst(queryParams?.sage_return_reference);
  const sageSubmissionTimestamp = queryFirst(queryParams?.sage_submission_timestamp) || datetimeLocalNow();
  if (!runId) redirect("/internal/accounting-vat");

  const previewValues: Record<number, string> = {};
  for (const item of BOXES) {
    const value = queryFirst(queryParams?.[`box${item.box}`]);
    if (value) previewValues[item.box] = value;
  }

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const [{ data: run }, { data: journals }, { data: blockers }, { data: reconRows }] = await Promise.all([
    db
      .from("vat_return_runs")
      .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box2_gbp, expected_box3_gbp, expected_box4_gbp, expected_box5_gbp, expected_box6_gbp, expected_box7_gbp, expected_box8_gbp, expected_box9_gbp")
      .eq("id", runId)
      .maybeSingle(),
    db
      .from("vat_return_adjustment_journals")
      .select("id, status")
      .eq("vat_return_run_id", runId),
    db
      .from("vat_return_blockers")
      .select("id, severity, status")
      .eq("vat_return_run_id", runId)
      .eq("severity", "blocker")
      .eq("status", "open"),
    db
      .from("vat_return_sage_reconstruction_snapshots")
      .select("id, box1_gbp, box2_gbp, box3_gbp, box4_gbp, box5_gbp, box6_gbp, box7_gbp, box8_gbp, box9_gbp")
      .eq("vat_return_run_id", runId)
      .order("created_at", { ascending: false })
      .limit(1),
  ]);
  if (!run) redirect("/internal/accounting-vat");

  const activeJournals = ((journals ?? []) as Row[]).filter((journal) => text(journal.status) !== "reversed");
  const allActiveJournalsFinal = activeJournals.length > 0 && activeJournals.every((journal) => ["posted_to_sage", "included_in_sage_return"].includes(text(journal.status)));
  const openBlockerCount = ((blockers ?? []) as Row[]).length;
  const noAdjustmentJournalsRequired = activeJournals.length === 0 && openBlockerCount === 0 && platformMatchesRecon(run as Row, ((reconRows ?? []) as Row[])[0] ?? {});
  const suggestedPurpose: UploadPurpose = allActiveJournalsFinal || noAdjustmentJournalsRequired ? "final_submission_evidence" : "draft_reconciliation";
  const defaultPurpose: UploadPurpose = "draft_reconciliation";
  const uploadPurpose = selectedPurpose ?? defaultPurpose;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-5xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-vat/returns/${runId}?tab=summary`} className="text-sm font-semibold text-sky-600">← Back to VAT return pack</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Sage VAT upload</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Upload Sage VAT file</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Use this single upload route for a draft reconciliation check or for final submitted Sage VAT return evidence. Final evidence is never assumed: choose that purpose and confirm before lock is attempted.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{label((run as Row).return_period_label || (run as Row).run_ref)}</div>
              <div>{date((run as Row).period_start_date)} → {date((run as Row).period_end_date)}</div>
            </div>
          </div>
        </section>

        {vatError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Sage VAT upload error: {vatError}</div> : null}

        <SageVatUploadForm
          runId={runId}
          uploadPurpose={uploadPurpose}
          defaultPurpose={defaultPurpose}
          suggestedPurpose={suggestedPurpose}
          previewValues={previewValues}
          sageReturnReference={sageReturnReference}
          sageSubmissionTimestamp={sageSubmissionTimestamp}
          showPreview={showPreview}
          missingBoxes={missingBoxes}
          fileName={fileName}
        />
      </div>
    </main>
  );
}
