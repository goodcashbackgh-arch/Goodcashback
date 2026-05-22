import type { ReactNode } from "react";
import { createClient } from "@/utils/supabase/server";
import {
  postSupplierCreditNoteBatchToSageWithAftercareAction,
  runSupplierCreditNoteAftercareAction,
} from "../../supplierCreditNotePostingAftercareActions";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function getPath(value: unknown, path: Array<string | number>): unknown {
  let current: unknown = value;
  for (const part of path) {
    if (typeof part === "number") {
      if (!Array.isArray(current)) return undefined;
      current = current[part];
    } else {
      if (!current || typeof current !== "object" || Array.isArray(current)) return undefined;
      current = (current as Row)[part];
    }
  }
  return current;
}

function firstText(value: unknown, paths: Array<Array<string | number>>) {
  for (const path of paths) {
    const found = text(getPath(value, path));
    if (found) return found;
  }
  return "";
}

function lineDescription(line: Row) {
  return firstText(line, [["description"], ["posting_description"], ["item_description"], ["source_description"], ["name"]]);
}

function lineLedgerId(line: Row) {
  return firstText(line, [["sage_ledger_account_id"], ["resolved_ledger_account_id"], ["ledger_account_id"]]);
}

function lineTaxId(line: Row) {
  return firstText(line, [["sage_tax_rate_id"], ["tax_rate_id"], ["resolved_tax_rate_id"]]);
}

function rowFacts(row: Row) {
  const payload = asObject(row.request_payload_json);
  const purchaseCreditNote = asObject(payload.purchase_credit_note);
  const resolverLines = asArray(payload.resolved_lines).map(asObject);
  const postedLines = asArray(purchaseCreditNote.credit_note_lines).map(asObject);
  const lines = resolverLines.length > 0 ? resolverLines : postedLines;
  const firstLine = lines[0] ?? {};
  const sourceFile = firstText(payload, [
    ["evidence", "credit_note_file_url"],
    ["evidence", "refund_proof_file_url"],
    ["evidence", "file_url"],
    ["credit_note_file_url"],
    ["refund_proof_file_url"],
    ["source_payload", "evidence", "credit_note_file_url"],
    ["source_payload", "evidence", "refund_proof_file_url"],
    ["source_payload", "evidence", "file_url"],
    ["source_payload", "credit_note_file_url"],
    ["source_payload", "refund_proof_file_url"],
  ]);
  const contactId = firstText(payload, [
    ["supplier_target", "sage_contact_id"],
    ["sage_header", "contact_id"],
    ["sage_header", "sage_contact_id"],
    ["source_payload", "supplier_target", "sage_contact_id"],
    ["purchase_credit_note", "contact_id"],
  ]);
  const ledgerId = lineLedgerId(firstLine);
  const taxRateId = lineTaxId(firstLine);
  const missingLineDescriptions = lines.filter((line) => !lineDescription(line)).length;
  return {
    sourceFile,
    contactId,
    ledgerId,
    taxRateId,
    lines,
    missingLineDescriptions,
    hasTargetFacts: Boolean(contactId && ledgerId && taxRateId && lines.length > 0 && missingLineDescriptions === 0),
  };
}

export default async function PostingBatchDetailLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ batch_id: string }> | { batch_id: string };
}) {
  const resolvedParams = await Promise.resolve(params);
  const batchId = resolvedParams.batch_id;

  let control: ReactNode = null;

  try {
    const supabase = await createClient();
    const { data: { user } } = await supabase.auth.getUser();

    if (user) {
      const { data, error } = await (supabase as any).rpc("internal_sage_posting_batch_detail_v1", {
        p_batch_id: batchId,
      });

      if (!error) {
        const rows = ((data ?? []) as Row[]).filter((row) => text(row.batch_id));
        const includedRows = rows.filter((row) => text(row.posting_status) !== "excluded");
        const creditNoteRows = includedRows.filter((row) => text(row.document_lane) === "supplier_credit_note");
        const liveFlag = process.env.SAGE_LIVE_POSTING_ENABLED === "true";
        const singleCreditNoteLane = creditNoteRows.length > 0 && creditNoteRows.length === includedRows.length;
        const dryRunOk = includedRows.length > 0 && includedRows.every((row) => text(row.payload_validation_status) === "dry_run_validated");
        const unposted = includedRows.every((row) => !text(row.sage_object_id) && text(row.posting_status) !== "posted" && !text(row.posted_at));
        const anyPosted = includedRows.some((row) => text(row.sage_object_id) || text(row.posting_status) === "posted" || text(row.posted_at));
        const missingTargetRows = includedRows.filter((row) => !rowFacts(row).hasTargetFacts).length;
        const missingSourceFileRows = includedRows.filter((row) => !rowFacts(row).sourceFile).length;
        const canPost = liveFlag && singleCreditNoteLane && dryRunOk && unposted && missingTargetRows === 0 && missingSourceFileRows === 0;
        const canRunAftercare = liveFlag && singleCreditNoteLane && anyPosted;
        const reasons: string[] = [];
        if (!liveFlag) reasons.push("live Sage posting flag is off");
        if (!singleCreditNoteLane) reasons.push("not a supplier credit note-only batch");
        if (!dryRunOk) reasons.push("dry-run validation is not complete");
        if (!unposted) reasons.push("one or more rows already posted");
        if (missingTargetRows > 0) reasons.push("Sage contact, ledger, tax or line facts are missing");
        if (missingSourceFileRows > 0) reasons.push("credit note source file is missing");

        if (singleCreditNoteLane) {
          control = (
            <div className="bg-slate-50 px-4 pt-4 text-slate-950 sm:px-6 lg:px-8">
              <section className="mx-auto max-w-[1900px] rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[0.2em] text-emerald-700">Supplier credit note posting</p>
                    <h2 className="mt-1 text-xl font-bold text-emerald-950">Post purchase credit note to Sage</h2>
                    <p className="mt-1 text-sm leading-5 text-emerald-900">
                      Post now runs aftercare: restore the resolver payload for the UI and try to attach the credit note PDF to the Sage transaction.
                    </p>
                    {!canPost && !anyPosted && reasons.length > 0 ? <p className="mt-2 text-xs font-bold text-amber-900">Blocked: {reasons.join("; ")}.</p> : null}
                    {anyPosted ? <p className="mt-2 text-xs font-bold text-amber-900">Posted batch: use aftercare to restore row facts and attach the source file if attachment did not complete.</p> : null}
                  </div>
                  <div className="flex shrink-0 flex-col gap-2 sm:flex-row">
                    <form action={postSupplierCreditNoteBatchToSageWithAftercareAction}>
                      <input type="hidden" name="batch_id" value={batchId} />
                      <button
                        type="submit"
                        disabled={!canPost}
                        className="rounded-2xl bg-emerald-700 px-5 py-3 text-sm font-extrabold text-white shadow-sm hover:bg-emerald-800 disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600"
                        title={canPost ? "Post supplier purchase credit note to Sage and run aftercare." : reasons.join("; ")}
                      >
                        Post supplier credit note to Sage
                      </button>
                    </form>
                    <form action={runSupplierCreditNoteAftercareAction}>
                      <input type="hidden" name="batch_id" value={batchId} />
                      <button
                        type="submit"
                        disabled={!canRunAftercare}
                        className="rounded-2xl bg-sky-700 px-5 py-3 text-sm font-extrabold text-white shadow-sm hover:bg-sky-800 disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600"
                        title={canRunAftercare ? "Restore row facts and attach source file for posted supplier credit note." : "Only available after a supplier credit note batch is posted."}
                      >
                        Run post-success aftercare
                      </button>
                    </form>
                  </div>
                </div>
              </section>
            </div>
          );
        }
      }
    }
  } catch {
    control = null;
  }

  return (
    <>
      {control}
      {children}
    </>
  );
}
