import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";

type Row = Record<string, unknown>;
type SearchParams = {
  status?: string;
  account_context?: string;
  direction?: string;
  importer_id?: string;
};

type SummaryCard = {
  label: string;
  count: number;
  amount: number;
  hint: string;
  tone: "emerald" | "amber" | "rose" | "sky" | "violet";
};

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(value));
}

function friendly(value: unknown) {
  const raw = text(value);
  if (!raw) return "—";
  return cleanUiText(raw.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase()));
}

function statusTone(status: string) {
  if (status === "controlled") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (status === "blocked") return "bg-rose-100 text-rose-800 ring-rose-200";
  if (status === "review_required") return "bg-violet-100 text-violet-800 ring-violet-200";
  return "bg-amber-100 text-amber-800 ring-amber-200";
}

function cardTone(tone: SummaryCard["tone"]) {
  if (tone === "emerald") return "border-emerald-200 bg-emerald-50 text-emerald-950";
  if (tone === "rose") return "border-rose-200 bg-rose-50 text-rose-950";
  if (tone === "sky") return "border-sky-200 bg-sky-50 text-sky-950";
  if (tone === "violet") return "border-violet-200 bg-violet-50 text-violet-950";
  return "border-amber-200 bg-amber-50 text-amber-950";
}

function actionHref(row: Row) {
  const lineId = text(row.dva_statement_line_id);
  const action = text(row.next_action);

  if (action === "order_funding" || action === "funding_or_inbound_classification") {
    return "/internal/funding";
  }
  if (action === "supplier_payment" || action === "supplier_payment_or_outbound_classification") {
    return `/internal/dva-reconciliation/workspace${lineId ? `?statement_line_id=${encodeURIComponent(lineId)}` : ""}`;
  }
  if (action === "main_bank_shipper_ap" || action === "completion_loyalty_source_pairing" || action === "completion_loyalty_destination_pairing" || action === "main_bank_shipper_or_loyalty_classification") {
    return "/internal/dva-reconciliation/main-bank";
  }
  if (action === "retailer_refund" || action === "final_balance_payment" || action === "matching_workspace") {
    return `/internal/dva-reconciliation/workspace${lineId ? `?statement_line_id=${encodeURIComponent(lineId)}` : ""}`;
  }
  if (action === "integrity_review") {
    return `/internal/dva-reconciliation/allocations${lineId ? `?statement_line_id=${encodeURIComponent(lineId)}` : ""}`;
  }
  if (action === "review_pack") {
    return "/internal/dva-reconciliation/review-pack";
  }
  return `/internal/dva-reconciliation/statement-interpretation${lineId ? `?line_id=${encodeURIComponent(lineId)}` : ""}`;
}

function actionLabel(row: Row) {
  const action = text(row.next_action);
  if (action === "order_funding") return "Open order funding";
  if (action === "supplier_payment") return "Open supplier matching";
  if (action === "main_bank_shipper_ap") return "Open main-bank AP";
  if (action === "completion_loyalty_source_pairing" || action === "completion_loyalty_destination_pairing") return "Open loyalty pairing";
  if (action === "integrity_review") return "Open reversals";
  if (action === "review_pack") return "Open review pack";
  if (action.includes("classification")) return "Classify statement line";
  return "Open control lane";
}

function filterHref(params: SearchParams, key: keyof SearchParams, value: string) {
  const next = new URLSearchParams();
  for (const [paramKey, paramValue] of Object.entries(params)) {
    if (!paramValue || paramKey === key) continue;
    next.set(paramKey, text(paramValue));
  }
  if (value) next.set(key, value);
  const query = next.toString();
  return `/internal/dva-reconciliation/control-summary${query ? `?${query}` : ""}`;
}

export default async function TreasuryControlSummaryPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const params = searchParams ? await searchParams : {};
  const selectedStatus = text(params.status) || "all";
  const selectedContext = text(params.account_context) || "all";
  const selectedDirection = text(params.direction) || "all";
  const selectedImporterId = text(params.importer_id);

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const [worklistResult, importersResult] = await Promise.all([
    (supabase as any).rpc("internal_statement_line_control_worklist_v1", {
      p_importer_id: selectedImporterId || null,
      p_limit: 500,
      p_offset: 0,
    }),
    supabase.from("importers").select("id, company_name, trading_name").order("company_name").limit(500),
  ]);

  const rows = (worklistResult.data ?? []) as Row[];
  const importers = (importersResult.data ?? []) as Row[];
  const importerById = new Map(importers.map((row) => [text(row.id), row]));

  const filteredRows = rows.filter((row) => {
    if (selectedStatus !== "all" && text(row.control_status) !== selectedStatus) return false;
    if (selectedContext !== "all" && text(row.statement_account_context) !== selectedContext) return false;
    if (selectedDirection !== "all" && text(row.effective_direction) !== selectedDirection) return false;
    return true;
  });

  const summaryCards: SummaryCard[] = [
    {
      label: "Open value",
      count: rows.filter((row) => text(row.control_status) === "open").length,
      amount: rows.filter((row) => text(row.control_status) === "open").reduce((sum, row) => sum + num(row.remaining_unconsumed_gbp), 0),
      hint: "Remaining value still needs a governed economic route.",
      tone: "amber",
    },
    {
      label: "Blocked integrity",
      count: rows.filter((row) => text(row.control_status) === "blocked").length,
      amount: rows.filter((row) => text(row.control_status) === "blocked").reduce((sum, row) => sum + Math.max(num(row.overconsumed_gbp), num(row.statement_gbp_amount)), 0),
      hint: "Overconsumption or incompatible principal economic lanes.",
      tone: "rose",
    },
    {
      label: "Review required",
      count: rows.filter((row) => text(row.control_status) === "review_required").length,
      amount: rows.filter((row) => text(row.control_status) === "review_required").reduce((sum, row) => sum + num(row.statement_gbp_amount), 0),
      hint: "Legacy or exceptional evidence needs staff review.",
      tone: "violet",
    },
    {
      label: "Controlled",
      count: rows.filter((row) => text(row.control_status) === "controlled").length,
      amount: rows.filter((row) => text(row.control_status) === "controlled").reduce((sum, row) => sum + num(row.statement_gbp_amount), 0),
      hint: "No remaining unexplained value under current controls.",
      tone: "emerald",
    },
    {
      label: "Funding eligible",
      count: rows.filter((row) => bool(row.funding_action_allowed_yn)).length,
      amount: rows.filter((row) => bool(row.funding_action_allowed_yn)).reduce((sum, row) => sum + num(row.remaining_unconsumed_gbp), 0),
      hint: "Importer DVA/card IN value eligible for order funding.",
      tone: "sky",
    },
  ];

  const actionGroups = new Map<string, { count: number; amount: number }>();
  for (const row of rows) {
    const action = text(row.next_action) || "unknown";
    const current = actionGroups.get(action) ?? { count: 0, amount: 0 };
    current.count += 1;
    current.amount += num(row.remaining_unconsumed_gbp);
    actionGroups.set(action, current);
  }

  const sortedActionGroups = Array.from(actionGroups.entries()).sort((left, right) => {
    if (right[1].count !== left[1].count) return right[1].count - left[1].count;
    return right[1].amount - left[1].amount;
  });

  return (
    <main className="mx-auto max-w-7xl px-6 py-10">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-slate-600 hover:text-slate-950">
            ← Treasury control hub
          </Link>
          <h1 className="mt-3 text-3xl font-bold tracking-tight text-slate-950">Treasury statement-control summary</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            One amount-aware view of statement truth, effective interpretation, consumed value, reserved value, remaining value, blockers and the next governed action.
          </p>
          <p className="mt-2 text-xs text-slate-500">
            Signed in as {text(staff.full_name) || "staff"} · {text(staff.role_type)}
          </p>
        </div>
        <Link
          href="/internal/dva-reconciliation/statement-interpretation"
          className="rounded-xl bg-sky-950 px-4 py-2 text-sm font-bold text-white hover:bg-sky-900"
        >
          Open interpretation workbench
        </Link>
      </div>

      {worklistResult.error ? (
        <div className="mt-6 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
          Statement-control worklist unavailable: {worklistResult.error.message}
        </div>
      ) : null}
      {importersResult.error ? (
        <div className="mt-6 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Importer names unavailable: {importersResult.error.message}
        </div>
      ) : null}

      <section className="mt-8 grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        {summaryCards.map((card) => (
          <article key={card.label} className={`rounded-2xl border p-5 ${cardTone(card.tone)}`}>
            <p className="text-xs font-bold uppercase tracking-wide opacity-75">{card.label}</p>
            <p className="mt-2 text-3xl font-bold">{card.count}</p>
            <p className="mt-1 text-sm font-semibold">{gbp(card.amount)}</p>
            <p className="mt-2 text-xs leading-5 opacity-75">{card.hint}</p>
          </article>
        ))}
      </section>

      <section className="mt-8 rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h2 className="text-lg font-bold text-slate-950">Next-action workload</h2>
            <p className="mt-1 text-sm text-slate-500">Resolver v2 determines the correct treasury lane; this summary does not invent a parallel route.</p>
          </div>
          <p className="text-xs font-semibold text-slate-500">{rows.length} statement lines</p>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {sortedActionGroups.map(([action, values]) => (
            <div key={action} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-sm font-bold text-slate-950">{friendly(action)}</p>
              <p className="mt-2 text-2xl font-bold text-slate-950">{values.count}</p>
              <p className="mt-1 text-xs text-slate-500">Remaining value: {gbp(values.amount)}</p>
            </div>
          ))}
        </div>
      </section>

      <form method="get" className="mt-8 rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <label className="block text-sm font-semibold text-slate-700">
            Control status
            <select name="status" defaultValue={selectedStatus} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm">
              <option value="all">All statuses</option>
              <option value="open">Open</option>
              <option value="blocked">Blocked</option>
              <option value="review_required">Review required</option>
              <option value="controlled">Controlled</option>
            </select>
          </label>
          <label className="block text-sm font-semibold text-slate-700">
            Account context
            <select name="account_context" defaultValue={selectedContext} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm">
              <option value="all">All account contexts</option>
              <option value="importer_dva_card_account">Importer DVA/card</option>
              <option value="main_company_bank_account">Main company bank</option>
            </select>
          </label>
          <label className="block text-sm font-semibold text-slate-700">
            Effective direction
            <select name="direction" defaultValue={selectedDirection} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm">
              <option value="all">IN and OUT</option>
              <option value="in">IN</option>
              <option value="out">OUT</option>
            </select>
          </label>
          <label className="block text-sm font-semibold text-slate-700">
            Importer
            <select name="importer_id" defaultValue={selectedImporterId} className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm">
              <option value="">All importers</option>
              {importers.map((importer) => (
                <option key={text(importer.id)} value={text(importer.id)}>
                  {text(importer.trading_name) || text(importer.company_name) || text(importer.id)}
                </option>
              ))}
            </select>
          </label>
        </div>
        <div className="mt-4 flex flex-wrap gap-3">
          <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Apply filters</button>
          <Link href="/internal/dva-reconciliation/control-summary" className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">
            Clear filters
          </Link>
        </div>
      </form>

      <section className="mt-8 space-y-3">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 className="text-xl font-bold text-slate-950">Statement-line control rows</h2>
            <p className="mt-1 text-sm text-slate-500">Showing {filteredRows.length} of {rows.length} rows.</p>
          </div>
          <div className="flex flex-wrap gap-2 text-xs font-semibold">
            <Link href={filterHref(params, "status", "blocked")} className="rounded-full bg-rose-100 px-3 py-1 text-rose-800">Blocked</Link>
            <Link href={filterHref(params, "status", "open")} className="rounded-full bg-amber-100 px-3 py-1 text-amber-800">Open</Link>
            <Link href={filterHref(params, "status", "controlled")} className="rounded-full bg-emerald-100 px-3 py-1 text-emerald-800">Controlled</Link>
          </div>
        </div>

        {filteredRows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-600">
            No statement-control rows match these filters.
          </div>
        ) : filteredRows.map((row) => {
          const lineId = text(row.dva_statement_line_id);
          const importer = importerById.get(text(row.importer_id));
          return (
            <article key={lineId} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex flex-wrap items-start justify-between gap-4">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusTone(text(row.control_status))}`}>
                      {friendly(row.control_status)}
                    </span>
                    <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700">
                      {text(row.effective_direction).toUpperCase() || "?"}
                    </span>
                    <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-semibold text-sky-800">
                      {friendly(row.effective_economic_classification)}
                    </span>
                    {row.interpretation_correction_id ? (
                      <span className="rounded-full bg-violet-100 px-2.5 py-1 text-xs font-semibold text-violet-800">Audited correction</span>
                    ) : null}
                  </div>
                  <h3 className="mt-3 text-lg font-bold text-slate-950">
                    {text(row.statement_date) || "No date"} · {gbp(row.statement_gbp_amount)}
                  </h3>
                  <p className="mt-1 truncate text-sm text-slate-600">{text(row.effective_display_description) || "No statement description"}</p>
                  <p className="mt-1 text-xs text-slate-500">
                    {text(importer?.trading_name) || text(importer?.company_name) || "Unknown importer"} · {friendly(row.statement_account_context)}
                  </p>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Link
                    href={`/internal/dva-reconciliation/statement-interpretation?line_id=${encodeURIComponent(lineId)}`}
                    className="rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-900 hover:bg-sky-100"
                  >
                    Inspect interpretation
                  </Link>
                  <Link
                    href={actionHref(row)}
                    className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-bold text-white hover:bg-slate-800"
                  >
                    {actionLabel(row)} →
                  </Link>
                </div>
              </div>

              <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
                <div className="rounded-2xl bg-slate-50 p-3 ring-1 ring-slate-200">
                  <p className="text-xs font-semibold text-slate-500">Statement amount</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{gbp(row.statement_gbp_amount)}</p>
                </div>
                <div className="rounded-2xl bg-slate-50 p-3 ring-1 ring-slate-200">
                  <p className="text-xs font-semibold text-slate-500">Consumed</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{gbp(row.active_consumed_gbp)}</p>
                </div>
                <div className="rounded-2xl bg-slate-50 p-3 ring-1 ring-slate-200">
                  <p className="text-xs font-semibold text-slate-500">Reserved</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{gbp(row.active_reserved_gbp)}</p>
                </div>
                <div className="rounded-2xl bg-slate-50 p-3 ring-1 ring-slate-200">
                  <p className="text-xs font-semibold text-slate-500">Remaining</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{gbp(row.remaining_unconsumed_gbp)}</p>
                </div>
                <div className={`rounded-2xl p-3 ring-1 ${num(row.overconsumed_gbp) > 0.01 ? "bg-rose-50 ring-rose-200" : "bg-slate-50 ring-slate-200"}`}>
                  <p className="text-xs font-semibold text-slate-500">Overconsumed</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{gbp(row.overconsumed_gbp)}</p>
                </div>
              </div>

              {text(row.blocker) ? (
                <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
                  <p className="text-xs font-bold uppercase tracking-wide text-rose-700">Blocker</p>
                  <p className="mt-1 font-semibold">{friendly(row.blocker)}</p>
                </div>
              ) : null}

              <p className="mt-4 text-xs text-slate-500">
                Resolver next action: <span className="font-semibold text-slate-800">{friendly(row.next_action)}</span>
                {bool(row.funding_action_allowed_yn) ? " · Funding action allowed" : ""}
              </p>
            </article>
          );
        })}
      </section>
    </main>
  );
}
