import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function cut(value: unknown, max = 90): string {
  const raw = text(value);
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw || "—";
}

export default async function VatBlockersPage() {
  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data, error } = await db
    .from("vat_return_blockers")
    .select("id, vat_return_run_id, blocker_code, severity, status, owner_role, source_table, source_ref, message, required_action, created_at")
    .order("created_at", { ascending: false })
    .limit(200);

  const rows = (data ?? []) as Row[];

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/accounting-vat" className="text-sm font-semibold text-sky-600">← Back to VAT dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT blockers</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">VAT blocker control</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Use this page to see what must be resolved before the return can move forward.</p>
        </section>

        {error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Read error: {error.message}</div> : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex items-center justify-between gap-3">
            <h2 className="text-lg font-semibold tracking-tight">Blockers</h2>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{rows.length} shown</span>
          </div>
          <div className="mt-4 grid gap-3">
            {rows.length === 0 ? <p className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No VAT blockers found.</p> : rows.map((row) => {
              const runId = text(row.vat_return_run_id);
              return (
                <div key={text(row.id)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <p className="text-sm font-bold text-slate-950">{cut(row.blocker_code, 60)}</p>
                      <p className="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-500">{cut(row.severity, 20)} · {cut(row.status, 20)} · {cut(row.owner_role, 24)}</p>
                    </div>
                    {runId ? <Link href={`/internal/accounting-vat/returns/${runId}`} className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-800">Open pack</Link> : null}
                  </div>
                  <p className="mt-3 text-sm leading-6 text-slate-700">{cut(row.message, 180)}</p>
                  <p className="mt-2 text-sm leading-6 text-slate-600">Action: {cut(row.required_action, 180)}</p>
                </div>
              );
            })}
          </div>
        </section>
      </div>
    </main>
  );
}
