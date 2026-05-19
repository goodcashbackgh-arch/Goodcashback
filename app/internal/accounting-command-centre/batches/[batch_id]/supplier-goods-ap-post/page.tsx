import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { postSupplierGoodsApBatchToSageAction } from "../../../apPostingActions";

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

export default async function SupplierGoodsApPostPage({
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
  if (!canAccess) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl rounded-3xl border border-amber-200 bg-amber-50 p-6 text-amber-900 shadow-sm">
          <Link href={`/internal/accounting-command-centre/batches/${batchId}`} className="text-sm font-semibold text-sky-700">← Posting batch</Link>
          <h1 className="mt-5 text-3xl font-bold tracking-tight">Supplier goods AP posting access required</h1>
          <p className="mt-3 text-sm leading-6">This action is admin-accounting controlled. Your current staff role is {text(staff.role_type)}.</p>
        </div>
      </main>
    );
  }

  const { data, error } = await (supabase as any).rpc("internal_sage_posting_batch_detail_v1", {
    p_batch_id: batchId,
  });

  const rows = ((data ?? []) as Row[]).filter((row) => text(row.batch_id));
  const includedRows = rows.filter((row) => text(row.posting_status) !== "excluded");
  const supplierRows = includedRows.filter((row) => text(row.document_lane) === "supplier_goods_ap");
  const dryRunOk = supplierRows.length > 0 && supplierRows.every((row) => text(row.payload_validation_status) === "dry_run_validated");
  const noPostedRows = supplierRows.every((row) => !text(row.sage_object_id) && text(row.posting_status) !== "posted");
  const laneOnly = supplierRows.length > 0 && supplierRows.length === includedRows.length;
  const liveFlag = process.env.SAGE_LIVE_POSTING_ENABLED === "true";
  const canPost = !error && liveFlag && laneOnly && dryRunOk && noPostedRows;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-5xl space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-command-centre/batches/${batchId}`} className="text-sm font-semibold text-sky-700">← Posting batch detail</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Supplier goods AP posting</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Guarded Sage purchase invoice post</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            This posts a supplier_goods_ap-only batch to Sage as purchase invoice(s). It remains blocked unless the batch is lane-specific, dry-run validated, unposted, and live posting is enabled.
          </p>
        </section>

        {successMessage ? <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{successMessage}</p> : null}
        {errorMessage ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{errorMessage}</p> : null}
        {error ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Batch detail RPC unavailable: {error.message}</p> : null}

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase text-slate-500">Included rows</p><p className="mt-1 text-2xl font-bold">{includedRows.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase text-slate-500">Supplier AP rows</p><p className="mt-1 text-2xl font-bold">{supplierRows.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase text-slate-500">Dry-run validated</p><p className="mt-1 text-2xl font-bold">{dryRunOk ? "Yes" : "No"}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase text-slate-500">Live flag</p><p className="mt-1 text-2xl font-bold">{liveFlag ? "On" : "Off"}</p></div>
        </section>

        {!laneOnly ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Blocked: this batch is not supplier_goods_ap-only.</p> : null}
        {!dryRunOk ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Blocked: every supplier goods AP row must be dry-run validated first.</p> : null}
        {!noPostedRows ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Blocked: one or more rows already have a Sage object id or posted status.</p> : null}
        {!liveFlag ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Blocked: SAGE_LIVE_POSTING_ENABLED is not true.</p> : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <form action={postSupplierGoodsApBatchToSageAction}>
            <input type="hidden" name="batch_id" value={batchId} />
            <button
              type="submit"
              disabled={!canPost}
              className="rounded-2xl bg-emerald-700 px-5 py-3 text-sm font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600"
            >
              Post supplier goods AP to Sage
            </button>
          </form>
          <p className="mt-3 text-xs leading-5 text-slate-500">
            The adapter sends net unit prices with mapped Sage tax rates, while guarding that frozen net + VAT equals approved gross. It refuses to send VAT-inclusive gross as Sage net.
          </p>
        </section>
      </div>
    </main>
  );
}
