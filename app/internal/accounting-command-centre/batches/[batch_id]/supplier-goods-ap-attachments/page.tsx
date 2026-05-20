import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { attachSupplierGoodsApSourcePdfAction } from "../../../apPostingActions";

type Row = Record<string, unknown>;
type SearchParams = Record<string, string | string[] | undefined>;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function chipClass(value: unknown) {
  const raw = text(value);
  if (["posted", "attached", "source_evidence_available"].includes(raw)) return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (["failed_retryable", "failed_terminal", "unsupported", "missing_source_evidence_file"].includes(raw)) return "border-rose-200 bg-rose-50 text-rose-900";
  if (["not_attempted", "pending"].includes(raw)) return "border-amber-200 bg-amber-50 text-amber-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function Chip({ value }: { value: unknown }) {
  const label = text(value).replaceAll("_", " ") || "—";
  return <span className={`inline-flex rounded-full border px-2 py-0.5 text-xs font-bold ${chipClass(value)}`}>{label}</span>;
}

export default async function SupplierGoodsApAttachmentsPage({
  params,
  searchParams,
}: {
  params: Promise<{ batch_id: string }> | { batch_id: string };
  searchParams?: Promise<SearchParams> | SearchParams;
}) {
  const resolvedParams = await Promise.resolve(params);
  const resolvedSearchParams = await Promise.resolve(searchParams ?? {});
  const batchId = resolvedParams.batch_id;
  const successMessage = text(resolvedSearchParams.success);
  const errorMessage = text(resolvedSearchParams.error);

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre?error=Accounting admin access required");

  const { data: batchRowsRaw, error: batchError } = await (supabase as any).rpc("internal_sage_posting_batch_detail_v1", {
    p_batch_id: batchId,
  });

  const batchRows = ((batchRowsRaw ?? []) as Row[])
    .filter((row) => text(row.batch_id) && text(row.document_lane) === "supplier_goods_ap" && text(row.source_table) === "supplier_invoices");

  const statusRows: Row[] = [];
  let statusError = "";
  for (const row of batchRows) {
    const sourceId = text(row.source_id);
    if (!sourceId) continue;
    const { data, error } = await (supabase as any).rpc("internal_sage_source_posting_status_v1", {
      p_source_table: "supplier_invoices",
      p_source_id: sourceId,
      p_document_lane: "supplier_goods_ap",
    });
    if (error) {
      statusError = error.message;
      continue;
    }
    const current = ((data ?? []) as Row[])[0];
    if (current) statusRows.push({ ...row, ...current });
  }

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-6xl space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-command-centre/batches/${batchId}`} className="text-sm font-semibold text-sky-700">← Posting batch detail</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Supplier goods AP evidence</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Sage source PDF attachment control</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            This attaches the existing platform supplier invoice PDF to the already-posted Sage purchase invoice. It does not accept a fresh upload here.
          </p>
          <p className="mt-2 text-xs font-semibold text-amber-800">
            Attachment attempts are logged separately from financial posting. If Sage rejects the attachment endpoint/shape, the purchase invoice remains posted and this page records the failure.
          </p>
        </section>

        {successMessage ? <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{successMessage}</p> : null}
        {errorMessage ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{errorMessage}</p> : null}
        {batchError ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Batch detail error: {batchError.message}</p> : null}
        {statusError ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Source status error: {statusError}</p> : null}

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3">
            <h2 className="text-xl font-semibold">Attachment rows</h2>
            <p className="mt-1 text-sm text-slate-500">Only posted supplier goods AP rows with a source PDF can be attached.</p>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-[1050px] divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Source</th>
                  <th className="px-3 py-2 text-left">Sage purchase invoice</th>
                  <th className="px-3 py-2 text-left">Attachment</th>
                  <th className="px-3 py-2 text-left">Source PDF</th>
                  <th className="px-3 py-2 text-left">Action</th>
                  <th className="px-3 py-2 text-left">Reason / error</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {statusRows.length === 0 ? (
                  <tr><td colSpan={6} className="px-3 py-8 text-center text-sm text-slate-500">No supplier goods AP attachment rows found.</td></tr>
                ) : statusRows.map((row) => {
                  const posted = text(row.source_posting_status) === "posted" && Boolean(text(row.sage_invoice_id));
                  const attached = text(row.sage_attachment_status) === "attached";
                  const sourceFile = text(row.sage_attachment_source_url);
                  const canAttach = posted && !attached && Boolean(sourceFile);
                  return (
                    <tr key={`${text(row.source_id)}-${text(row.current_snapshot_id)}`} className="align-top">
                      <td className="px-3 py-3">
                        <p className="font-bold text-slate-950">{text(row.reference_text) || text(row.order_ref) || "Supplier invoice"}</p>
                        <p className="mt-1 font-mono text-xs text-slate-500">{text(row.source_id)}</p>
                      </td>
                      <td className="px-3 py-3 space-y-1">
                        <Chip value={row.source_posting_status} />
                        <p className="font-mono text-xs text-slate-600">{text(row.sage_invoice_id) || "No Sage id"}</p>
                      </td>
                      <td className="px-3 py-3 space-y-1">
                        <Chip value={row.sage_attachment_status} />
                        {text(row.sage_attachment_object_id) ? <p className="font-mono text-xs text-slate-600">{text(row.sage_attachment_object_id)}</p> : null}
                      </td>
                      <td className="px-3 py-3">
                        {sourceFile ? <a href={sourceFile} target="_blank" rel="noreferrer" className="font-bold text-sky-700 underline">Open source PDF</a> : <span className="font-semibold text-rose-700">Missing source PDF</span>}
                      </td>
                      <td className="px-3 py-3">
                        <form action={attachSupplierGoodsApSourcePdfAction}>
                          <input type="hidden" name="batch_id" value={batchId} />
                          <input type="hidden" name="snapshot_id" value={text(row.current_snapshot_id)} />
                          <button
                            type="submit"
                            disabled={!canAttach}
                            className="rounded-xl bg-emerald-700 px-3 py-2 text-xs font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600"
                          >
                            Attach PDF to Sage
                          </button>
                        </form>
                      </td>
                      <td className="px-3 py-3 text-xs text-slate-600">
                        {text(row.sage_attachment_error_message) || text(row.sage_attachment_error_code) || "—"}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
