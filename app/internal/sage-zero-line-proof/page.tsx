import Link from "next/link";
import { runSageZeroLineProofAction } from "./actions";

type SearchParams = Record<string, string | string[] | undefined>;

function value(params: SearchParams, key: string) {
  const raw = params[key];
  return Array.isArray(raw) ? raw[0] ?? "" : raw ?? "";
}

export default async function SageZeroLineProofPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const code = value(params, "code");
  const proven = code === "sage_zero_line_runtime_proven";
  const ran = Boolean(code);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-8 text-slate-950 sm:px-6">
      <div className="mx-auto max-w-3xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/accounting-command-centre">← Accounting Command Centre</Link>
          </div>
          <p className="mt-6 text-xs font-bold uppercase tracking-[0.2em] text-amber-600">Temporary production diagnostic</p>
          <h1 className="mt-2 text-2xl font-semibold">Sage £0 purchase-invoice line proof</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            This isolated action uses only the dedicated supplier <strong>Goods To Ship API Zero Test</strong> with reference <strong>GTSZERO</strong>.
            It does not call the Goodcashback AP posting pipeline and performs no database writes.
          </p>
          <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-950">
            It will create one disposable Sage purchase invoice containing a £1 control line and a £0 line, read the invoice back, then delete it immediately.
            If the existing Sage access token is not safely usable without refresh, it stops before any Sage write.
          </div>
        </section>

        {ran ? (
          <section className={`rounded-3xl border p-6 shadow-sm ${proven ? "border-emerald-300 bg-emerald-50" : "border-rose-300 bg-rose-50"}`}>
            <h2 className="text-lg font-semibold">{proven ? "Runtime proof passed" : "Runtime proof did not pass"}</h2>
            <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
              {["code", "reference", "create_status", "sage_validation_error", "get_status", "delete_status", "zero_line_retained", "zero_line_unit_price", "zero_line_tax_amount", "control_line_retained", "cleanup_complete", "sage_write_made", "match_count", "http_status", "create_request_id", "get_request_id", "delete_request_id"].map((key) => {
                const v = value(params, key);
                if (!v) return null;
                return <div key={key} className="rounded-xl bg-white/80 p-3 ring-1 ring-black/5"><dt className="text-xs font-bold uppercase tracking-wide text-slate-500">{key.replaceAll("_", " ")}</dt><dd className="mt-1 break-all font-mono text-xs text-slate-900">{v}</dd></div>;
              })}
            </dl>
            {!proven ? <p className="mt-4 text-sm font-semibold text-rose-900">Do not infer Sage £0-line acceptance unless the result code is exactly <span className="font-mono">sage_zero_line_runtime_proven</span> and cleanup is complete.</p> : null}
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Run once</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">The action is staff-authenticated, production-main only, fixed to GTSZERO, and refuses token refresh.</p>
          <form action={runSageZeroLineProofAction} className="mt-5">
            <input type="hidden" name="confirmation" value="RUN GTSZERO" />
            <button className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-bold text-white hover:bg-slate-800">Run disposable Sage £0 proof</button>
          </form>
        </section>
      </div>
    </main>
  );
}
