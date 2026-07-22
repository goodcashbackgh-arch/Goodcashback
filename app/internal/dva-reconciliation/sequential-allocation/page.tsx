import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { allocateNextSupplierInvoiceAction } from "./actions";

type SearchParams = {
  line_id?: string;
  order_id?: string;
  success?: string;
  error?: string;
};

type Row = Record<string, unknown>;

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
  return raw.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function lineHref(lineId: string, orderId = "") {
  const params = new URLSearchParams();
  if (lineId) params.set("line_id", lineId);
  if (orderId) params.set("order_id", orderId);
  return `/internal/dva-reconciliation/sequential-allocation?${params.toString()}`;
}

export default async function SequentialSupplierAllocationPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const params = searchParams ? await searchParams : {};
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

  const [worklistResult, candidateResult] = await Promise.all([
    (supabase as any).rpc("internal_statement_line_control_worklist_v1", {
      p_importer_id: null,
      p_limit: 500,
      p_offset: 0,
    }),
    supabase
      .from("supplier_payment_candidate_status_vw")
      .select(
        "supplier_invoice_id, order_id, order_ref, importer_id, retailer_id, invoice_ref, review_status, invoice_total_gbp, confirmed_matched_gbp, remaining_unmatched_gbp, supplier_payment_ready_yn, blocker, selectable_yn",
      )
      .order("order_ref", { ascending: false })
      .limit(1000),
  ]);

  const allControlRows = (worklistResult.data ?? []) as Row[];
  const supplierOutRows = allControlRows.filter((row) => {
    const classification = text(row.effective_economic_classification);
    return (
      text(row.statement_account_context) === "importer_dva_card_account" &&
      text(row.effective_direction) === "out" &&
      ["unclassified", "supplier_payment"].includes(classification) &&
      text(row.control_status) !== "blocked" &&
      num(row.remaining_unconsumed_gbp) > 0.01
    );
  });

  const requestedLineId = text(params.line_id);
  const selectedLineId = supplierOutRows.some((row) => text(row.dva_statement_line_id) === requestedLineId)
    ? requestedLineId
    : text(supplierOutRows[0]?.dva_statement_line_id);
  const selectedLine = supplierOutRows.find((row) => text(row.dva_statement_line_id) === selectedLineId) ?? null;

  const allocationResult = selectedLineId
    ? await supabase
        .from("dva_statement_line_allocations")
        .select(
          "id, dva_statement_line_id, supplier_invoice_id, order_id, allocated_gbp_amount, allocation_type, allocation_status, source_bank_account_mapping_code, source_wallet_code, notes, created_at, confirmed_at, reversed_at",
        )
        .eq("dva_statement_line_id", selectedLineId)
        .order("created_at", { ascending: true })
    : { data: [], error: null };

  const allocations = (allocationResult.data ?? []) as Row[];
  const activeSupplierAllocations = allocations.filter(
    (row) => text(row.allocation_type) === "supplier_invoice" && text(row.allocation_status) === "confirmed",
  );
  const activeNonSupplierAllocations = allocations.filter(
    (row) => text(row.allocation_status) !== "reversed" && text(row.allocation_type) !== "supplier_invoice",
  );
  const openAllocations = allocations.filter((row) => ["draft", "held"].includes(text(row.allocation_status)));

  const lockedOrderIds = [...new Set(activeSupplierAllocations.map((row) => text(row.order_id)).filter(Boolean))];
  const lockedOrderId = lockedOrderIds.length === 1 ? lockedOrderIds[0] : "";
  const lineIntegrityBlocked = lockedOrderIds.length > 1 || activeNonSupplierAllocations.length > 0 || openAllocations.length > 0;
  const lineRemaining = num(selectedLine?.remaining_unconsumed_gbp);
  const selectedImporterId = text(selectedLine?.importer_id);

  const candidates = ((candidateResult.data ?? []) as Row[]).filter((row) => {
    if (!selectedImporterId || text(row.importer_id) !== selectedImporterId) return false;
    if (lockedOrderId && text(row.order_id) !== lockedOrderId) return false;
    return true;
  });

  const availableOrderIds = [...new Set(candidates.map((row) => text(row.order_id)).filter(Boolean))];
  const requestedOrderId = text(params.order_id);
  const selectedOrderId = lockedOrderId || (availableOrderIds.includes(requestedOrderId) ? requestedOrderId : availableOrderIds[0] ?? "");
  const selectedOrderCandidates = candidates.filter((row) => text(row.order_id) === selectedOrderId);
  const existingInvoiceIds = new Set(activeSupplierAllocations.map((row) => text(row.supplier_invoice_id)).filter(Boolean));
  const nextInvoiceCandidates = selectedOrderCandidates.filter((row) => {
    return (
      !existingInvoiceIds.has(text(row.supplier_invoice_id)) &&
      bool(row.selectable_yn) &&
      bool(row.supplier_payment_ready_yn) &&
      text(row.review_status) === "approved_current" &&
      num(row.remaining_unmatched_gbp) > 0.01
    );
  });

  const sourceMappings = [...new Set(activeSupplierAllocations.map((row) => text(row.source_bank_account_mapping_code)).filter(Boolean))];
  const sourceWallets = [...new Set(activeSupplierAllocations.map((row) => text(row.source_wallet_code)).filter(Boolean))];
  const inheritedSourceValid = activeSupplierAllocations.length === 0 || sourceMappings.length === 1;

  const selectedOrderRef = text(
    selectedOrderCandidates[0]?.order_ref ||
      activeSupplierAllocations.find((row) => text(row.order_id) === selectedOrderId)?.order_id,
  );

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <Link href="/internal/dva-reconciliation/control-summary" className="text-sm font-semibold text-sky-700 hover:text-sky-900">
                ← Treasury statement-control summary
              </Link>
              <p className="mt-6 text-sm font-semibold uppercase tracking-[0.2em] text-sky-600">Sequential supplier allocation</p>
              <h1 className="mt-2 text-3xl font-semibold">Apply one physical OUT to the next invoice</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                Allocate an OUT invoice-by-invoice. The first allocation fixes the order, importer, retailer and source mapping. Every later allocation must inherit that same economic identity until the physical OUT is exhausted.
              </p>
              <p className="mt-2 text-sm text-slate-500">{text(staff.full_name) || "Staff"} · {text(staff.role_type)}</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link href="/internal/dva-reconciliation/multi-invoice" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">
                Atomic bundle route
              </Link>
              <Link href="/internal/dva-reconciliation/allocations" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">
                Matching & reversals
              </Link>
            </div>
          </div>

          {params.success ? (
            <div className="mt-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{params.success}</div>
          ) : null}
          {params.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{params.error}</div>
          ) : null}
          {worklistResult.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
              Statement-control worklist unavailable: {worklistResult.error.message}
            </div>
          ) : null}
          {candidateResult.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
              Supplier-payment candidates unavailable: {candidateResult.error.message}
            </div>
          ) : null}
          {allocationResult.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
              Existing allocations unavailable: {allocationResult.error.message}
            </div>
          ) : null}
        </section>

        <section className="grid gap-5 xl:grid-cols-[0.85fr_1.15fr]">
          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-end justify-between gap-3">
              <div>
                <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Step 1</p>
                <h2 className="mt-1 text-xl font-semibold">Select an eligible supplier-payment OUT</h2>
              </div>
              <span className="text-xs font-semibold text-slate-500">{supplierOutRows.length} open</span>
            </div>

            <div className="mt-4 max-h-[72vh] space-y-3 overflow-y-auto pr-1">
              {supplierOutRows.length === 0 ? (
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">
                  No importer DVA/card OUT rows currently qualify for sequential supplier allocation.
                </div>
              ) : supplierOutRows.map((row) => {
                const id = text(row.dva_statement_line_id);
                const active = id === selectedLineId;
                return (
                  <Link
                    key={id}
                    href={lineHref(id)}
                    className={`block rounded-2xl border p-4 transition ${active ? "border-sky-500 bg-sky-50 ring-2 ring-sky-200" : "border-slate-200 bg-white hover:border-sky-200 hover:bg-sky-50"}`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="font-semibold">{text(row.statement_date) || "No date"} · {gbp(row.statement_gbp_amount)}</p>
                        <p className="mt-1 truncate text-sm text-slate-600">{text(row.effective_display_description) || text(row.raw_description) || "No statement description"}</p>
                        <p className="mt-2 text-xs text-slate-500">Confirmed allocated {gbp(row.confirmed_allocated_gbp)} · active allocations {num(row.active_allocation_count)}</p>
                      </div>
                      <div className="text-right">
                        <span className="rounded-full bg-white px-2.5 py-1 text-xs font-bold text-sky-800 ring-1 ring-sky-200">OUT</span>
                        <p className="mt-3 text-xs font-semibold text-slate-500">Remaining</p>
                        <p className="text-sm font-bold text-slate-950">{gbp(row.remaining_unconsumed_gbp)}</p>
                      </div>
                    </div>
                  </Link>
                );
              })}
            </div>
          </article>

          <div className="space-y-5">
            <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Step 2</p>
              <h2 className="mt-1 text-xl font-semibold">Confirm the locked economic identity</h2>

              {!selectedLine ? (
                <p className="mt-4 text-sm text-amber-800">Select an OUT statement line.</p>
              ) : (
                <>
                  <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                    <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                      <p className="text-xs font-semibold text-slate-500">Physical OUT</p>
                      <p className="mt-1 text-lg font-bold">{gbp(selectedLine.statement_gbp_amount)}</p>
                    </div>
                    <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                      <p className="text-xs font-semibold text-slate-500">Already allocated</p>
                      <p className="mt-1 text-lg font-bold">{gbp(selectedLine.confirmed_allocated_gbp)}</p>
                    </div>
                    <div className="rounded-2xl bg-sky-50 p-4 ring-1 ring-sky-200">
                      <p className="text-xs font-semibold text-sky-700">Remaining to allocate</p>
                      <p className="mt-1 text-lg font-bold text-sky-950">{gbp(lineRemaining)}</p>
                    </div>
                    <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                      <p className="text-xs font-semibold text-slate-500">Allocation sequence</p>
                      <p className="mt-1 text-lg font-bold">{activeSupplierAllocations.length + 1}</p>
                    </div>
                  </div>

                  {lineIntegrityBlocked || !inheritedSourceValid ? (
                    <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
                      <p className="font-bold">Sequential allocation is blocked.</p>
                      <p className="mt-1 text-xs leading-5">
                        {lockedOrderIds.length > 1 ? "Existing supplier allocations span more than one order. " : ""}
                        {activeNonSupplierAllocations.length > 0 ? "The statement line has an active non-supplier economic use. " : ""}
                        {openAllocations.length > 0 ? "Draft or held allocations must be resolved first. " : ""}
                        {!inheritedSourceValid ? "Existing supplier allocations do not resolve to one inherited source mapping." : ""}
                      </p>
                    </div>
                  ) : null}

                  {activeSupplierAllocations.length > 0 ? (
                    <div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-950">
                      <p className="font-bold">Sequence locked by the first confirmed allocation</p>
                      <div className="mt-2 grid gap-2 sm:grid-cols-2">
                        <p>Order: <span className="font-semibold">{selectedOrderRef || lockedOrderId}</span></p>
                        <p>Source mapping: <span className="font-semibold">{sourceMappings[0] || "Missing"}</span></p>
                        <p>Source wallet: <span className="font-semibold">{sourceWallets[0] || "None"}</span></p>
                        <p>Confirmed allocations: <span className="font-semibold">{activeSupplierAllocations.length}</span></p>
                      </div>
                    </div>
                  ) : (
                    <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
                      The first allocation will resolve and permanently lock this OUT to one order, importer, retailer and supplier-payment source mapping.
                    </div>
                  )}
                </>
              )}
            </article>

            {selectedLine ? (
              <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-wrap items-end justify-between gap-3">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Step 3</p>
                    <h2 className="mt-1 text-xl font-semibold">Select the next invoice</h2>
                  </div>
                  <p className="text-xs font-semibold text-slate-500">{nextInvoiceCandidates.length} eligible</p>
                </div>

                {!lockedOrderId && availableOrderIds.length > 0 ? (
                  <div className="mt-4">
                    <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Choose the order for the first allocation</p>
                    <div className="mt-2 flex flex-wrap gap-2">
                      {availableOrderIds.map((orderId) => {
                        const first = candidates.find((row) => text(row.order_id) === orderId);
                        const active = orderId === selectedOrderId;
                        return (
                          <Link
                            key={orderId}
                            href={lineHref(selectedLineId, orderId)}
                            className={`rounded-full px-4 py-2 text-sm font-semibold ${active ? "bg-slate-950 text-white" : "border border-slate-300 bg-white text-slate-800 hover:bg-slate-50"}`}
                          >
                            {text(first?.order_ref) || orderId}
                          </Link>
                        );
                      })}
                    </div>
                  </div>
                ) : null}

                {selectedOrderId ? (
                  <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                    Current order: <span className="font-bold text-slate-950">{selectedOrderRef || selectedOrderId}</span>
                    {lockedOrderId ? " · locked by existing allocation" : " · will lock when the first allocation succeeds"}
                  </div>
                ) : null}

                <div className="mt-4 space-y-4">
                  {nextInvoiceCandidates.length === 0 ? (
                    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">
                      No further approved and supplier-payment-ready invoice is eligible for this order. Existing matched invoices are excluded automatically.
                    </div>
                  ) : nextInvoiceCandidates.map((invoice) => {
                    const invoiceId = text(invoice.supplier_invoice_id);
                    const invoiceRemaining = num(invoice.remaining_unmatched_gbp);
                    const maximum = Math.min(lineRemaining, invoiceRemaining);
                    const disabled = lineIntegrityBlocked || !inheritedSourceValid || maximum <= 0.01;
                    return (
                      <form key={invoiceId} action={allocateNextSupplierInvoiceAction} className="rounded-2xl border border-slate-200 bg-white p-4 ring-1 ring-slate-100">
                        <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
                        <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
                        <input type="hidden" name="order_id" value={selectedOrderId} />

                        <div className="grid gap-4 lg:grid-cols-[1fr_190px] lg:items-end">
                          <div>
                            <div className="flex flex-wrap items-center gap-2">
                              <p className="font-bold text-slate-950">Invoice {text(invoice.invoice_ref) || invoiceId}</p>
                              <span className="rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-bold text-emerald-800">Eligible next invoice</span>
                            </div>
                            <p className="mt-2 text-sm text-slate-600">
                              Total {gbp(invoice.invoice_total_gbp)} · confirmed matched {gbp(invoice.confirmed_matched_gbp)} · remaining {gbp(invoice.remaining_unmatched_gbp)}
                            </p>
                            <p className="mt-1 text-xs text-slate-500">
                              Review status {friendly(invoice.review_status)} · supplier-payment ready {bool(invoice.supplier_payment_ready_yn) ? "Yes" : "No"}
                            </p>
                            {text(invoice.blocker) ? (
                              <p className="mt-2 text-xs font-semibold text-amber-800">View blocker: {friendly(invoice.blocker)}</p>
                            ) : null}
                          </div>

                          <label className="text-xs font-bold uppercase tracking-wide text-slate-500">
                            Allocate GBP
                            <input
                              name="allocated_gbp_amount"
                              type="number"
                              min="0.01"
                              max={maximum.toFixed(2)}
                              step="0.01"
                              required
                              defaultValue={maximum.toFixed(2)}
                              disabled={disabled}
                              className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-base font-bold text-slate-950 disabled:bg-slate-100"
                            />
                          </label>
                        </div>

                        <textarea
                          name="notes"
                          rows={2}
                          className="mt-4 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                          placeholder="Optional allocation note"
                        />
                        <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
                          <p className="text-xs text-slate-500">Maximum allowed now: {gbp(maximum)}</p>
                          <button
                            disabled={disabled}
                            className="rounded-xl bg-sky-950 px-5 py-3 text-sm font-bold text-white hover:bg-sky-900 disabled:bg-slate-300 disabled:text-slate-600"
                          >
                            Allocate this invoice and continue
                          </button>
                        </div>
                      </form>
                    );
                  })}
                </div>
              </article>
            ) : null}

            {activeSupplierAllocations.length > 0 ? (
              <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex items-end justify-between gap-3">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Current sequence</p>
                    <h2 className="mt-1 text-xl font-semibold">Confirmed invoice allocations</h2>
                  </div>
                  <Link href={`/internal/dva-reconciliation/allocations?statement_line_id=${encodeURIComponent(selectedLineId)}`} className="text-xs font-bold text-sky-700 hover:text-sky-900">
                    Review or reverse →
                  </Link>
                </div>

                <div className="mt-4 space-y-3">
                  {activeSupplierAllocations.map((allocation, index) => {
                    const invoice = ((candidateResult.data ?? []) as Row[]).find(
                      (row) => text(row.supplier_invoice_id) === text(allocation.supplier_invoice_id),
                    );
                    return (
                      <div key={text(allocation.id)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                        <div className="flex flex-wrap items-start justify-between gap-3">
                          <div>
                            <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Allocation {index + 1}</p>
                            <p className="mt-1 font-bold text-slate-950">Invoice {text(invoice?.invoice_ref) || text(allocation.supplier_invoice_id)}</p>
                            <p className="mt-1 text-xs text-slate-500">Confirmed {text(allocation.confirmed_at) || text(allocation.created_at) || "—"}</p>
                          </div>
                          <p className="text-lg font-bold text-slate-950">{gbp(allocation.allocated_gbp_amount)}</p>
                        </div>
                        <p className="mt-2 text-xs text-slate-500">
                          Source {text(allocation.source_bank_account_mapping_code) || "Missing"}
                          {text(allocation.source_wallet_code) ? ` · wallet ${text(allocation.source_wallet_code)}` : ""}
                        </p>
                      </div>
                    );
                  })}
                </div>
              </article>
            ) : null}
          </div>
        </section>
      </div>
    </main>
  );
}
