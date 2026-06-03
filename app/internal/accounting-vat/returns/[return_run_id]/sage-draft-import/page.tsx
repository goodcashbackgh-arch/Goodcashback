import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { importSageDraftVatReturnTotalsAction, previewSageDraftVatReturnTotalsAction, recordFinalSageVatSubmissionEvidenceAction } from "./actions";

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

function amount(value: unknown): string {
  const parsed = num(value) ?? 0;
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(parsed);
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
  const defaultPurpose: UploadPurpose = allActiveJournalsFinal || noAdjustmentJournalsRequired ? "final_submission_evidence" : "draft_reconciliation";
  const uploadPurpose = selectedPurpose ?? defaultPurpose;
  const isFinal = uploadPurpose === "final_submission_evidence";

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

        {showPreview ? (
          <section className={`rounded-3xl border p-5 shadow-sm ${missingBoxes.length ? "border-amber-200 bg-amber-50 text-amber-950" : "border-emerald-200 bg-emerald-50 text-emerald-950"}`}>
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 className="text-xl font-semibold tracking-tight">Preview extracted Sage boxes</h2>
                <p className="mt-1 text-sm leading-6 opacity-90">
                  Preview purpose: <span className="font-bold">{isFinal ? "Final submitted Sage VAT return evidence" : "Draft reconciliation check"}</span>. {fileName ? `Source file: ${fileName}.` : "Source: manual values."}
                </p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-bold ${missingBoxes.length ? "bg-amber-100 text-amber-800" : "bg-emerald-100 text-emerald-800"}`}>
                {missingBoxes.length ? `Missing Box ${missingBoxes.join(", ")}` : "Ready to save"}
              </span>
            </div>
            {isFinal ? (
              <p className="mt-3 rounded-2xl border border-amber-200 bg-white/70 p-3 text-sm font-semibold text-amber-900">
                Final evidence will compare submitted Sage boxes to platform expected boxes. If they do not match, the return will not lock.
              </p>
            ) : null}
            <div className="mt-4 overflow-x-auto rounded-2xl border border-white/70 bg-white">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Box</th><th className="px-3 py-2">Meaning</th><th className="px-3 py-2">Preview value</th></tr></thead>
                <tbody className="divide-y divide-slate-100">
                  {BOXES.map((item) => <tr key={item.box}><td className="px-3 py-2 font-bold text-slate-950">Box {item.box}</td><td className="px-3 py-2 text-slate-600">{item.label}</td><td className="px-3 py-2 font-semibold text-slate-900">{previewValues[item.box] !== undefined ? amount(previewValues[item.box]) : "—"}</td></tr>)}
                </tbody>
              </table>
            </div>
            <p className="mt-3 text-xs leading-5 opacity-90">The values have been copied into the manual boxes below. If they are correct, use the purpose-specific save button. The browser clears file uploads after preview, so reselect the file before saving only if you need its hash recorded; otherwise it saves the confirmed manual Sage totals.</p>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold tracking-tight">Upload Sage VAT return export</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Upload a Sage VAT return XLSX/CSV/text export, or enter Boxes 1–9 manually. Draft mode saves a reconstruction snapshot; final mode records submitted values and asks the match/lock RPC to lock only when the submitted boxes match the platform expected boxes.
          </p>

          <form action={importSageDraftVatReturnTotalsAction} className="mt-6 grid gap-5">
            <input type="hidden" name="vat_return_run_id" value={runId} />

            <section className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <h3 className="font-semibold text-slate-950">Upload purpose</h3>
              <p className="mt-1 text-xs leading-5 text-slate-600">The default follows the return state, but admins can switch purpose manually. Choosing final requires an explicit confirmation and calls the Sage match/lock RPC.</p>
              <div className="mt-3 grid gap-3 md:grid-cols-2">
                <label className="flex gap-3 rounded-2xl border border-slate-200 bg-white p-4 text-sm">
                  <input type="radio" name="upload_purpose" value="draft_reconciliation" defaultChecked={uploadPurpose === "draft_reconciliation"} />
                  <span><span className="block font-bold text-slate-950">Draft reconciliation check</span><span className="mt-1 block text-xs leading-5 text-slate-600">Save a Sage reconstruction snapshot only. This does not lock the return.</span></span>
                </label>
                <label className="flex gap-3 rounded-2xl border border-slate-200 bg-white p-4 text-sm">
                  <input type="radio" name="upload_purpose" value="final_submission_evidence" defaultChecked={uploadPurpose === "final_submission_evidence"} />
                  <span><span className="block font-bold text-slate-950">Final submitted Sage VAT return evidence</span><span className="mt-1 block text-xs leading-5 text-slate-600">Record final Sage values and lock only if the RPC match rules pass.</span></span>
                </label>
              </div>
              <p className="mt-3 text-xs font-semibold text-slate-600">Current default: {defaultPurpose === "final_submission_evidence" ? "Final submission evidence" : "Draft reconciliation"}.</p>
            </section>

            <section className="grid gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 md:grid-cols-2">
              <label className="grid gap-2 text-sm">
                <span className="font-semibold text-amber-950">Sage return reference (required for final)</span>
                <input name="sage_return_reference" defaultValue={sageReturnReference} placeholder="Sage/HMRC return reference" className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" />
              </label>
              <label className="grid gap-2 text-sm">
                <span className="font-semibold text-amber-950">Sage submission timestamp (required for final)</span>
                <input name="sage_submission_timestamp" type="datetime-local" defaultValue={sageSubmissionTimestamp} className="rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" />
              </label>
              <label className="flex items-start gap-3 rounded-2xl border border-amber-200 bg-white p-3 text-sm md:col-span-2">
                <input className="mt-1" type="checkbox" name="confirm_final_sage_submission" value="yes" />
                <span><span className="font-bold text-amber-950">Confirm final Sage submission evidence</span><span className="mt-1 block text-xs leading-5 text-amber-900">Required only for final evidence. The action is blocked without this confirmation.</span></span>
              </label>
            </section>

            <label className="grid gap-2 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
              <span className="font-semibold text-slate-950">Sage VAT file</span>
              <span className="text-xs leading-5 text-slate-600">XLSX, CSV, TSV or plain-text export. Keep it under 2MB.</span>
              <input name="sage_draft_file" type="file" accept=".xlsx,.csv,.tsv,.txt,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/csv,text/plain" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" />
            </label>

            <section className="rounded-2xl border border-slate-200 bg-white p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h3 className="font-semibold text-slate-950">Manual override / confirmation</h3>
                  <p className="mt-1 text-xs leading-5 text-slate-600">Required boxes are 1, 4, 6 and 7. Optional boxes can be left blank unless Sage shows a value. Box 3 and Box 5 are calculated if blank.</p>
                </div>
                <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800">Admin must check against Sage</span>
              </div>

              <div className="mt-4 grid gap-3 md:grid-cols-3">
                {BOXES.map((item) => (
                  <label key={item.box} className="grid gap-1 text-sm">
                    <span className="font-medium text-slate-800">Box {item.box}{item.optional ? " (optional)" : ""}</span>
                    <span className="text-xs text-slate-500">{item.label}</span>
                    <input name={`box${item.box}_gbp`} inputMode="decimal" defaultValue={previewValues[item.box] ?? ""} placeholder="0.00" className="rounded-xl border border-slate-200 px-3 py-2 text-sm" />
                  </label>
                ))}
              </div>
            </section>

            <div className="grid gap-3 md:grid-cols-2">
              <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm leading-6 text-sky-900">
                Draft reconciliation saves into the existing Sage reconstruction snapshot history and returns to the summary tab.
              </div>
              <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
                Final evidence calls the existing lock RPC; blockers, journal state and box mismatches remain enforced by the database.
              </div>
            </div>

            <div className="flex flex-wrap gap-3">
              <button formAction={previewSageDraftVatReturnTotalsAction} className="rounded-xl border border-sky-200 bg-sky-50 px-5 py-3 text-sm font-bold text-sky-800 hover:bg-sky-100">Preview extracted boxes</button>
              <button name="upload_purpose" value="draft_reconciliation" formAction={importSageDraftVatReturnTotalsAction} className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-bold text-white hover:bg-slate-800">Save draft reconciliation snapshot</button>
              <button name="upload_purpose" value="final_submission_evidence" formAction={recordFinalSageVatSubmissionEvidenceAction} className="rounded-xl border border-emerald-700 bg-emerald-600 px-5 py-3 text-sm font-bold text-white hover:bg-emerald-700">Record final Sage submission and lock if matched</button>
            </div>
          </form>
        </section>
      </div>
    </main>
  );
}
