import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type DiagnosticRow = {
  section: string;
  severity: string;
  data: unknown;
};

function severityClass(severity: string | null | undefined) {
  if (severity === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (severity === "blocker") return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-slate-200 bg-slate-50 text-slate-900";
}

function prettySection(value: string) {
  return value.replace(/^\d+_/, "").replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export default async function InternalAccessControlPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("internal_access_control_diagnostic_v1");
  const rows = (data ?? []) as DiagnosticRow[];
  const blockers = rows.filter((row) => row.severity === "blocker").length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal">← Internal dashboard</Link>
            <Link href="/internal/fx-rates">Daily FX rates</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Access control / onboarding diagnostic</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Contract v1 stage: additive tables, legacy-safe backfill, supervisor scope defaults, and diagnostics before any enforcement. This page must pass before /auth/check is changed to membership-first routing.</p>
            </div>
            <div className={`rounded-2xl border px-4 py-3 text-sm ${blockers === 0 && !error ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-rose-200 bg-rose-50 text-rose-900"}`}>
              <div className="font-semibold">{error ? "Migration/RPC not ready" : blockers === 0 ? "No backfill blockers" : `${blockers} blocker section${blockers === 1 ? "" : "s"}`}</div>
              <div>{staff.full_name} · {staff.role_type}</div>
            </div>
          </div>
          {error ? (
            <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{error.message}. Run migration 20260620_multi_tenant_access_layer_v1.sql first.</p>
          ) : null}
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950 shadow-sm">
          <h2 className="text-lg font-semibold">Enforcement remains off</h2>
          <p className="mt-2">This page is diagnostic only. It does not replace legacy login routing, does not restrict existing users, and does not enable platform access enforcement.</p>
        </section>

        <section className="grid gap-4">
          {rows.map((row) => (
            <article key={row.section} className={`rounded-3xl border p-5 shadow-sm ${severityClass(row.severity)}`}>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <p className="text-xs font-bold uppercase tracking-[0.2em] opacity-70">{row.section}</p>
                  <h2 className="mt-1 text-xl font-semibold">{prettySection(row.section)}</h2>
                </div>
                <span className="rounded-full border border-current px-3 py-1 text-xs font-bold uppercase tracking-wide">{row.severity}</span>
              </div>
              <pre className="mt-4 max-h-[36rem] overflow-auto rounded-2xl bg-white/80 p-4 text-xs leading-5 text-slate-900 ring-1 ring-black/5">{JSON.stringify(row.data, null, 2)}</pre>
            </article>
          ))}
        </section>
      </div>
    </main>
  );
}
