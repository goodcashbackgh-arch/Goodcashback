import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { catalogItemValue } from "@/lib/accounting/catalog-cache";
import { saveCoaSageMappingAction, syncFullSageLedgerAccountsAction } from "./actions";

type SearchParams = {
  q?: string;
  family?: string;
  success?: string;
  error?: string;
};

type MappingRow = {
  mapping_code: string;
  mapping_group: string | null;
  display_name: string | null;
  description: string | null;
  value_kind: string | null;
  required_for: string[] | null;
  sage_external_id: string | null;
  sage_display_name: string | null;
  mapping_status: string | null;
  blocker: string | null;
  notes: string | null;
};

type LedgerRow = {
  sage_external_id: string;
  display_name: string | null;
  reference_text: string | null;
  code_text: string | null;
  sage_type: string | null;
  active_status: string | null;
  raw_preview_json: Record<string, unknown> | null;
};

const FAMILY_LABELS: Record<string, string> = {
  all: "All GLs",
  sales_income: "Sales / income",
  purchases_expenses: "Purchases / expenses",
  vat_tax: "VAT / tax control",
  bank_cash: "Bank / cash",
  assets: "Assets",
  liabilities: "Liabilities",
  suspense_clearing: "Suspense / clearing",
  inactive: "Inactive / hidden",
  other: "Other",
};

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function loweredLedgerText(row: LedgerRow) {
  return `${row.display_name ?? ""} ${row.reference_text ?? ""} ${row.code_text ?? ""} ${row.sage_type ?? ""} ${row.active_status ?? ""}`.toLowerCase();
}

function ledgerFamily(row: LedgerRow) {
  const haystack = loweredLedgerText(row);
  const code = text(row.code_text);
  const codeNum = Number(code.replace(/\D/g, ""));
  if (/inactive|hidden|false|archived/.test(haystack)) return "inactive";
  if (/vat|tax|output tax|input tax|purchase tax|sales tax/.test(haystack)) return "vat_tax";
  if (/suspense|clearing|control|adjustment/.test(haystack)) return "suspense_clearing";
  if (/bank|cash|current account|payment|receipt/.test(haystack)) return "bank_cash";
  if (/sales|income|revenue|turnover|export/.test(haystack) || (codeNum >= 4000 && codeNum < 5000)) return "sales_income";
  if (/purchase|expense|cost|freight|shipping|delivery|direct cost|overhead/.test(haystack) || (codeNum >= 5000 && codeNum < 8000)) return "purchases_expenses";
  if (/asset|debtor|receivable|prepayment|stock|inventory/.test(haystack) || (codeNum >= 1000 && codeNum < 2000)) return "assets";
  if (/liability|creditor|payable|accrual|loan/.test(haystack) || (codeNum >= 2000 && codeNum < 3000)) return "liabilities";
  return "other";
}

function expectedFamily(mappingCode: string) {
  if (mappingCode === "VAT_OUTPUT_NET_CONTROL_LEDGER") return "sales_income";
  if (mappingCode === "VAT_INPUT_NET_CONTROL_LEDGER") return "purchases_expenses";
  if (mappingCode === "VAT_OUTPUT_BOX_CONTROL_LEDGER") return "vat_tax";
  if (mappingCode === "VAT_INPUT_BOX_CONTROL_LEDGER") return "vat_tax";
  if (mappingCode === "VAT_ADJUSTMENT_SUSPENSE_LEDGER") return "suspense_clearing";
  if (/bank|receipt|payment/i.test(mappingCode)) return "bank_cash";
  if (/sales|income|output/i.test(mappingCode)) return "sales_income";
  if (/purchase|expense|input|ap/i.test(mappingCode)) return "purchases_expenses";
  return "all";
}

function statusClass(status: string | null | undefined) {
  if (status === "configured") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (status === "missing") return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-amber-200 bg-amber-50 text-amber-900";
}

function familyWarning(mapping: MappingRow, ledger: LedgerRow | null) {
  if (!ledger) return "";
  const expected = expectedFamily(mapping.mapping_code);
  if (expected === "all") return "";
  const actual = ledgerFamily(ledger);
  if (expected === actual) return "";
  if (expected === "vat_tax" && actual === "suspense_clearing") return "Check: this looks like clearing/control, not a VAT control account.";
  if (expected === "sales_income" && actual !== "sales_income") return "Check: Box 6 should normally map to sales/income nominal, not VAT/control/bank.";
  if (expected === "purchases_expenses" && actual !== "purchases_expenses") return "Check: Box 7 should normally map to purchases/expense nominal.";
  if (expected === "suspense_clearing" && actual !== "suspense_clearing") return "Check: balancing line should normally map to suspense/clearing/control.";
  return `Check category: expected ${FAMILY_LABELS[expected] ?? expected}, detected ${FAMILY_LABELS[actual] ?? actual}.`;
}

function ledgerOption(row: LedgerRow) {
  return {
    id: row.sage_external_id,
    display: row.display_name || row.sage_external_id,
    reference: row.reference_text || "",
    type: row.sage_type || "",
  };
}

function MappingCard({ mapping, ledgers }: { mapping: MappingRow; ledgers: LedgerRow[] }) {
  const current = ledgers.find((ledger) => ledger.sage_external_id === mapping.sage_external_id) ?? null;
  const expected = expectedFamily(mapping.mapping_code);
  const preferredLedgers = expected === "all" ? ledgers : ledgers.filter((ledger) => ledgerFamily(ledger) === expected);
  const dropdownLedgers = preferredLedgers.length > 0 ? preferredLedgers : ledgers;
  const warning = familyWarning(mapping, current);

  return (
    <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-lg font-semibold text-slate-950">{mapping.display_name ?? mapping.mapping_code}</h3>
            <span className={`rounded-full border px-2.5 py-1 text-xs font-bold ${statusClass(mapping.mapping_status)}`}>{friendly(mapping.mapping_status)}</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs font-bold text-slate-700">Expected: {FAMILY_LABELS[expected] ?? friendly(expected)}</span>
          </div>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">{mapping.description ?? "—"}</p>
          <p className="mt-2 font-mono text-xs text-slate-500">{mapping.mapping_code}</p>
          {warning ? <p className="mt-3 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-950">{warning}</p> : null}
          {mapping.blocker ? <p className="mt-3 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-900">{friendly(mapping.blocker)}</p> : null}
        </div>
        <div className="rounded-2xl bg-slate-50 p-4 text-sm ring-1 ring-slate-200 lg:w-96">
          <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Current mapped Sage GL</p>
          <p className="mt-1 break-all font-semibold text-slate-950">{mapping.sage_display_name || current?.display_name || "Not configured"}</p>
          <p className="mt-1 break-all font-mono text-[11px] text-slate-600">{mapping.sage_external_id || "—"}</p>
          <p className="mt-2 text-xs text-slate-500">Detected CoA group: {current ? FAMILY_LABELS[ledgerFamily(current)] : "—"}</p>
        </div>
      </div>

      <form action={saveCoaSageMappingAction} className="mt-5 grid gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-4 lg:grid-cols-[1.4fr_1fr_1fr_1.1fr_auto]">
        <input type="hidden" name="mapping_code" value={mapping.mapping_code} />
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Pick Sage GL ({dropdownLedgers.length} shown)
          <select name="mapping_pick" defaultValue="" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
            <option value="">Leave unchanged</option>
            {dropdownLedgers.map((ledger) => (
              <option key={`${mapping.mapping_code}-${ledger.sage_external_id}`} value={catalogItemValue(ledgerOption(ledger))}>
                {ledger.code_text ? `${ledger.code_text} · ` : ""}{ledger.display_name || ledger.sage_external_id}{ledger.sage_type ? ` · ${ledger.sage_type}` : ""}{mapping.sage_external_id === ledger.sage_external_id ? " · current" : ""}
              </option>
            ))}
          </select>
        </label>
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Manual Sage id<input name="sage_external_id" defaultValue={mapping.sage_external_id ?? ""} placeholder="Fallback only" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Manual display name<input name="sage_display_name" defaultValue={mapping.sage_display_name ?? ""} placeholder="Fallback only" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">Notes<input name="notes" defaultValue={mapping.notes ?? ""} placeholder="Why this is correct" className="mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal text-slate-950" /></label>
        <div className="flex items-end"><button className="w-full rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Save</button></div>
      </form>
    </article>
  );
}

function LedgerTable({ ledgers, mappedIds }: { ledgers: LedgerRow[]; mappedIds: Set<string> }) {
  return (
    <div className="overflow-x-auto rounded-2xl border border-slate-200">
      <table className="min-w-[1050px] divide-y divide-slate-200 text-xs">
        <thead className="bg-slate-100 uppercase tracking-wide text-slate-500">
          <tr>
            <th className="px-3 py-2 text-left">Code</th>
            <th className="px-3 py-2 text-left">Sage name</th>
            <th className="px-3 py-2 text-left">CoA group</th>
            <th className="px-3 py-2 text-left">Sage type/status</th>
            <th className="px-3 py-2 text-left">Sage ID</th>
            <th className="px-3 py-2 text-left">Mapped?</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100 bg-white">
          {ledgers.length === 0 ? <tr><td colSpan={6} className="px-3 py-6 text-center text-sm text-slate-500">No cached ledger accounts match this filter.</td></tr> : ledgers.map((ledger) => (
            <tr key={ledger.sage_external_id} className="align-top hover:bg-slate-50">
              <td className="max-w-[110px] px-3 py-2 font-mono text-slate-700">{ledger.code_text || "—"}</td>
              <td className="max-w-[300px] px-3 py-2 font-semibold text-slate-950">{ledger.display_name || "—"}<div className="mt-1 text-[11px] font-normal text-slate-500">{ledger.reference_text || "—"}</div></td>
              <td className="px-3 py-2"><span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 font-semibold text-slate-700">{FAMILY_LABELS[ledgerFamily(ledger)]}</span></td>
              <td className="max-w-[190px] px-3 py-2 text-slate-700">{[ledger.sage_type, ledger.active_status].filter(Boolean).join(" · ") || "—"}</td>
              <td className="max-w-[250px] truncate px-3 py-2 font-mono text-[11px] text-slate-700" title={ledger.sage_external_id}>{ledger.sage_external_id}</td>
              <td className="px-3 py-2">{mappedIds.has(ledger.sage_external_id) ? <span className="rounded-full border border-emerald-200 bg-emerald-50 px-2.5 py-1 font-bold text-emerald-900">mapped</span> : <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 font-semibold text-slate-500">available</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default async function SageCoaMappingWorkbenchPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
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

  const { data: mappingData, error: mappingError } = await (supabase as any).rpc("internal_sage_mapping_control_v1");
  const mappings = ((mappingData ?? []) as MappingRow[]).filter((row) => row.value_kind === "ledger_account_id");
  const vatMappings = mappings.filter((row) => row.mapping_group === "vat_adjustment_journals" || row.mapping_code.startsWith("VAT_"));
  const otherMappings = mappings.filter((row) => !vatMappings.some((vat) => vat.mapping_code === row.mapping_code));

  const { data: connection } = await supabaseAdmin
    .from("sage_connections")
    .select("id")
    .in("status", ["connected", "token_expired", "refresh_failed"])
    .order("updated_at", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: business } = connection?.id ? await supabaseAdmin
    .from("sage_businesses")
    .select("id")
    .eq("connection_id", connection.id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle() : { data: null } as { data: null };

  let ledgerQuery = connection?.id ? supabaseAdmin
    .from("sage_catalog_cache")
    .select("sage_external_id, display_name, reference_text, code_text, sage_type, active_status, raw_preview_json")
    .eq("sage_connection_id", connection.id)
    .eq("category_key", "ledger_accounts")
    .order("code_text", { ascending: true })
    .order("display_name", { ascending: true }) : null;
  if (ledgerQuery && business?.id) ledgerQuery = ledgerQuery.eq("sage_business_row_id", business.id);
  if (ledgerQuery && !business?.id) ledgerQuery = ledgerQuery.is("sage_business_row_id", null);
  const { data: ledgerData } = ledgerQuery ? await ledgerQuery : { data: [] as LedgerRow[] };
  const allLedgers = (ledgerData ?? []) as LedgerRow[];

  const selectedFamily = text(params.family) || "all";
  const q = text(params.q).toLowerCase();
  const filteredLedgers = allLedgers.filter((ledger) => {
    const familyOk = selectedFamily === "all" || ledgerFamily(ledger) === selectedFamily;
    const queryOk = !q || loweredLedgerText(ledger).includes(q) || text(ledger.sage_external_id).toLowerCase().includes(q);
    return familyOk && queryOk;
  });
  const mappedIds = new Set(mappings.map((row) => row.sage_external_id).filter(Boolean) as string[]);
  const familyCounts = Object.keys(FAMILY_LABELS).reduce((acc, family) => ({
    ...acc,
    [family]: family === "all" ? allLedgers.length : allLedgers.filter((ledger) => ledgerFamily(ledger) === family).length,
  }), {} as Record<string, number>);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/sage-mapping">← Back to Sage mapping control</Link>
            <Link href="/internal/accounting-command-centre">Accounting Command Centre</Link>
            <Link href="/internal/sage-ready">Ready for Sage queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Sage CoA workbench</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Chart of Accounts mapping workbench</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Browse the cached Sage ledger accounts by CoA structure, then map the right GL to the platform requirement. This page reuses the existing mapping RPC and does not change party matching or posting logic.</p>
            </div>
            <form action={syncFullSageLedgerAccountsAction}>
              <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Sync full Sage ledger list</button>
            </form>
          </div>
          {params.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">{params.success}</p> : null}
          {params.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-900">{params.error}</p> : null}
          {mappingError ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-900">Mapping control unavailable: {mappingError.message}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Cached Sage GLs</p><p className="mt-1 text-2xl font-semibold">{allLedgers.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Filtered GLs</p><p className="mt-1 text-2xl font-semibold">{filteredLedgers.length}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Ledger mappings</p><p className="mt-1 text-2xl font-semibold">{mappings.length}</p></div>
          <div className="rounded-3xl border border-rose-200 bg-rose-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Missing ledger mappings</p><p className="mt-1 text-2xl font-semibold">{mappings.filter((row) => row.mapping_status === "missing").length}</p></div>
        </section>

        <section className="rounded-3xl border border-sky-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">VAT adjustment journal mappings</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">These are the accounts needed before the controlled VAT journal posting test. Category warnings are advisory guardrails only; saving still uses the existing mapping RPC.</p>
          <div className="mt-5 grid gap-4">
            {vatMappings.length === 0 ? <p className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">No VAT adjustment ledger mapping rows returned.</p> : vatMappings.map((mapping) => <MappingCard key={mapping.mapping_code} mapping={mapping} ledgers={allLedgers} />)}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Sage GL catalogue</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Filter the full cached CoA. Create new accounts in Sage first, then click “Sync full Sage ledger list”.</p>
            </div>
            <form className="grid gap-2 sm:grid-cols-[1fr_220px_auto]" action="/internal/sage-mapping/coa">
              <input name="q" defaultValue={params.q ?? ""} placeholder="Search name, code, ID, type" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
              <select name="family" defaultValue={selectedFamily} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                {Object.entries(FAMILY_LABELS).map(([key, label]) => <option key={key} value={key}>{label} ({familyCounts[key] ?? 0})</option>)}
              </select>
              <button className="rounded-xl bg-sky-700 px-4 py-2 text-sm font-bold text-white hover:bg-sky-800">Filter</button>
            </form>
          </div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-bold">
            {Object.entries(FAMILY_LABELS).map(([key, label]) => (
              <Link key={key} href={`/internal/sage-mapping/coa?family=${key}`} className={`rounded-full border px-3 py-1 ${selectedFamily === key ? "border-sky-300 bg-sky-50 text-sky-900" : "border-slate-200 bg-slate-50 text-slate-700"}`}>{label} · {familyCounts[key] ?? 0}</Link>
            ))}
          </div>
          <div className="mt-5"><LedgerTable ledgers={filteredLedgers} mappedIds={mappedIds} /></div>
        </section>

        {otherMappings.length > 0 ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Other ledger mappings</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Existing non-VAT ledger mappings remain available here without changing the old mapping page.</p>
            <div className="mt-5 grid gap-4">
              {otherMappings.map((mapping) => <MappingCard key={mapping.mapping_code} mapping={mapping} ledgers={allLedgers} />)}
            </div>
          </section>
        ) : null}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-semibold">Safety note</h2>
          <p className="mt-2">This is a mapping UI only. It does not post to Sage, change invoice status, change party matching, or alter existing posting adapters.</p>
        </section>
      </div>
    </main>
  );
}
