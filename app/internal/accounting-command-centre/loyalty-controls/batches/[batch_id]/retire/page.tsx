import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { reopenCompletionLoyaltySageBatchAction } from "../reopenActions";

type Params = { batch_id: string } | Promise<{ batch_id: string }>;
type SearchParams = Record<string, string | string[] | undefined> | Promise<Record<string, string | string[] | undefined>>;

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function hasAccountingAccess(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

export default async function RetireCompletionLoyaltyBatchPage({ params, searchParams }: { params: Params; searchParams?: SearchParams }) {
  const { batch_id: batchId } = await Promise.resolve(params);
  const resolvedSearchParams = await Promise.resolve(searchParams ?? {});
  const pageError = text(resolvedSearchParams.error);
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  const canAccess = text(staff.role_type) === "admin" || hasAccountingAccess((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  const { data } = await (supabase as any).rpc("internal_completion_loyalty_sage_batch_detail_v1", { p_batch_id: batchId });
  const rows = (data ?? []) as Row[];
  const first = rows[0] ?? {};

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-3xl space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-command-centre/loyalty-controls/batches/${batchId}`} className="text-sm font-semibold text-sky-700">← Back to loyalty Sage batch</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.18em] text-rose-500">Controlled retire action</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Retire unposted loyalty Sage batch</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Use this only where the loyalty Sage batch did not create any Sage object. The database function blocks the action if a linked step has a Sage object id, posted timestamp, or posted status.
          </p>
          {pageError ? (
            <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold leading-6 text-amber-950">
              {pageError}
            </div>
          ) : null}
          <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
            <p><span className="font-semibold">Batch:</span> {text(first.batch_ref) || batchId}</p>
            <p><span className="font-semibold">Status:</span> {text(first.batch_status) || "not loaded"}</p>
            <p><span className="font-semibold">Rows:</span> {text(first.batch_row_count) || String(rows.length)}</p>
          </div>
          <form action={reopenCompletionLoyaltySageBatchAction} className="mt-5 space-y-3">
            <input type="hidden" name="batch_id" value={batchId} />
            <label className="block text-sm font-semibold text-slate-700">
              Note
              <input name="note" defaultValue="Retired from confirmation page before any Sage object was created." className="mt-1 w-full rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm font-normal text-slate-950" />
            </label>
            <button type="submit" className="rounded-2xl border border-rose-200 bg-rose-50 px-4 py-2 text-sm font-bold text-rose-700 hover:bg-rose-100">
              Retire batch and return to Step 3
            </button>
          </form>
        </section>
      </div>
    </main>
  );
}
