import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { requestRefundDocumentResubmissionAction } from "../resubmissionActions";

type SearchParams = { success?: string; error?: string };

type Submission = {
  id: string;
  dispute_id: string;
  document_mode: string | null;
  credit_note_ref: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  supplier_approval_status: string | null;
  supplier_control_status: string | null;
  supervisor_review_status: string | null;
  match_status: string | null;
  notes: string | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function label(value: string | null | undefined) {
  return String(value ?? "—").replaceAll("_", " ");
}

export default async function RefundDocumentResubmissionPage({
  params,
  searchParams,
}: {
  params: Promise<{ submission_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { submission_id: submissionId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data, error } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, document_mode, credit_note_ref, expected_credit_note_total_gbp, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, supplier_approval_status, supplier_control_status, supervisor_review_status, match_status, notes")
    .eq("id", submissionId)
    .maybeSingle();

  if (error || !data) redirect(`/internal/supplier-draft-ready?error=${encodeURIComponent(error?.message ?? "Refund evidence submission not found")}`);

  const submission = data as Submission;
  const amount = submission.expected_credit_note_total_gbp ?? submission.captured_refund_amount_abs_gbp ?? submission.expected_exception_amount_abs_gbp ?? 0;
  const alreadyApproved = submission.supplier_approval_status === "approved_current" || submission.supplier_control_status === "approved_current";

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-3xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/refund-document-control/${submissionId}`} className="text-sm font-semibold text-sky-700">← Back to refund document control</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Supervisor rejection / resubmission</p>
          <h1 className="mt-2 text-3xl font-semibold">Request refund document resubmission</h1>
          <p className="mt-2 text-sm text-slate-600">Use only when the uploaded credit note, refund proof or no-document evidence is wrong, incomplete or needs to be resubmitted by the operator.</p>
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Submission being rejected</h2>
          <div className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
            <p>Mode<br /><strong>{label(submission.document_mode)}</strong></p>
            <p>Reference<br /><strong>{submission.credit_note_ref ?? "—"}</strong></p>
            <p>Amount<br /><strong>{gbp(amount)}</strong></p>
            <p>Approval<br /><strong>{label(submission.supplier_approval_status)}</strong></p>
            <p>Control<br /><strong>{label(submission.supplier_control_status)}</strong></p>
            <p>Match<br /><strong>{label(submission.match_status)}</strong></p>
          </div>
          {submission.notes ? <p className="mt-4 rounded-2xl bg-slate-50 p-3 text-sm text-slate-700">{submission.notes}</p> : null}
        </section>

        {alreadyApproved ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-6 text-sm text-rose-900">
            This refund document is already approved current. Resubmission is blocked after approval.
          </section>
        ) : (
          <form action={requestRefundDocumentResubmissionAction} className="space-y-4 rounded-3xl border border-amber-200 bg-white p-6 shadow-sm">
            <input type="hidden" name="refund_evidence_submission_id" value={submission.id} />
            <label className="block text-sm font-semibold text-slate-700">
              Reason to send back to operator
              <textarea
                name="resubmission_reason"
                required
                rows={5}
                className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                placeholder="Example: wrong credit note uploaded; amount does not match retailer response; missing credit-note pages; needs corrected refund proof."
              />
            </label>
            <div className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              This will block the current submission, mark supervisor review as rejected, write an audit message, and send the operator back to resubmit/correct the refund evidence. It does not delete the old document.
            </div>
            <button className="rounded-xl bg-amber-700 px-5 py-3 text-sm font-semibold text-white hover:bg-amber-600">Reject and request resubmission</button>
          </form>
        )}
      </div>
    </main>
  );
}
