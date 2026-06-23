"use client";

import { useMemo, useState } from "react";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import { allocateMainBankLineToShipperApAction, matchMainBankLineToCompletionLoyaltyAction } from "./actions";
import { allocateMainBankFxFeeAction } from "./fxFeeActions";

type Row = Record<string, unknown>;
type TargetMode = "shipper_ap" | "completion_loyalty";

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

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

function round2(value: number) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function short(value: unknown, max = 56) {
  const raw = cleanUiText(text(value));
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function cardClass(selected: boolean, tone: "bank" | "target") {
  if (!selected) return "border-slate-200 bg-white";
  return tone === "bank" ? "border-sky-500 bg-sky-50 ring-2 ring-sky-200" : "border-emerald-500 bg-emerald-50 ring-2 ring-emerald-200";
}

function residualLabel(value: string) {
  if (value === "fx_card_difference") return "FX/payment variance";
  if (value === "bank_fee") return "Bank fee";
  return "Unmatched hold";
}

function safeAvailable(line: Row | null, residual: number) {
  if (!line) return 0;
  const readModelRemaining = round2(num(line.remaining_gbp));
  const legacyRemainingAfterResidual = round2(Math.max(num(line.amount_gbp) - num(line.allocated_gbp) - residual, 0));
  return Math.max(Math.min(readModelRemaining, legacyRemainingAfterResidual), 0);
}

export default function MainBankAllocationController({
  lines,
  targets,
  loyaltyTargets,
  residualRows,
  targetMode,
}: {
  lines: Row[];
  targets: Row[];
  loyaltyTargets: Row[];
  residualRows: Row[];
  targetMode: TargetMode;
}) {
  const firstLineId = text(lines[0]?.statement_line_id);
  const firstLoyaltyOrderId = text(loyaltyTargets[0]?.order_id);
  const [selectedLineId, setSelectedLineId] = useState(firstLineId);
  const [selectedTargetIds, setSelectedTargetIds] = useState<string[]>([]);
  const [selectedLoyaltyOrderId, setSelectedLoyaltyOrderId] = useState(firstLoyaltyOrderId);
  const [residualType, setResidualType] = useState("fx_card_difference");
  const [manualResidual, setManualResidual] = useState("");

  const residualByLine = useMemo(() => {
    const map = new Map<string, number>();
    for (const row of residualRows) {
      const lineId = text(row.dva_statement_line_id);
      map.set(lineId, round2((map.get(lineId) ?? 0) + num(row.allocated_gbp_amount)));
    }
    return map;
  }, [residualRows]);

  const residualByType = useMemo(() => {
    const map = new Map<string, number>();
    for (const row of residualRows) {
      const kind = text(row.allocation_type);
      map.set(kind, round2((map.get(kind) ?? 0) + num(row.allocated_gbp_amount)));
    }
    return map;
  }, [residualRows]);

  const selectedLine = lines.find((row) => text(row.statement_line_id) === selectedLineId) ?? null;
  const selectedResidualExisting = residualByLine.get(selectedLineId) ?? 0;
  const selectedLineAvailable = safeAvailable(selectedLine, selectedResidualExisting);
  const selectedTargets = targets.filter((row) => selectedTargetIds.includes(text(row.shipping_document_id)));
  const selectedTargetTotal = round2(selectedTargets.reduce((sum, row) => sum + num(row.remaining_gbp), 0));
  const selectedLoyaltyTarget = loyaltyTargets.find((row) => text(row.order_id) === selectedLoyaltyOrderId) ?? null;
  const selectedLoyaltyAmount = round2(num(selectedLoyaltyTarget?.suggested_reward_gbp));
  const selectedPrimaryTotal = targetMode === "completion_loyalty" ? selectedLoyaltyAmount : selectedTargetTotal;
  const loyaltyModeNeedsTarget = targetMode === "completion_loyalty" && !selectedLoyaltyTarget;
  const residualCanBeExplained = targetMode !== "completion_loyalty" || Boolean(selectedLoyaltyTarget);
  const residualAmount = residualCanBeExplained ? round2(manualResidual ? Number(manualResidual) || 0 : Math.max(selectedLineAvailable - selectedPrimaryTotal, 0)) : 0;
  const explainedTotal = round2(selectedPrimaryTotal + residualAmount);
  const gap = round2(selectedLineAvailable - explainedTotal);
  const canConfirmAp = Boolean(targetMode === "shipper_ap" && selectedLineId && selectedTargetIds.length > 0 && selectedTargetTotal <= selectedLineAvailable + 0.01);
  const canConfirmLoyalty = Boolean(targetMode === "completion_loyalty" && selectedLineId && selectedLoyaltyOrderId && selectedLoyaltyAmount > 0 && selectedLoyaltyAmount <= selectedLineAvailable + 0.01);
  const canConfirmResidual = Boolean(residualCanBeExplained && selectedLineId && residualAmount > 0 && residualAmount <= selectedLineAvailable + 0.01);
  const exact = Math.abs(gap) < 0.01;

  function toggleTarget(id: string) {
    setSelectedTargetIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  }

  return (
    <div className="space-y-5 pb-64 sm:pb-56">
      <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-emerald-900 shadow-sm">
          <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">Main-bank lines</p>
          <p className="mt-1 text-2xl font-extrabold">{lines.length}</p>
          <p className="mt-1 text-xs leading-4">{gbp(lines.reduce((sum, row) => sum + safeAvailable(row, residualByLine.get(text(row.statement_line_id)) ?? 0), 0))} available after consumed amounts</p>
        </div>
        <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-emerald-900 shadow-sm">
          <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{targetMode === "completion_loyalty" ? "Loyalty targets" : "Open shipper charges"}</p>
          <p className="mt-1 text-2xl font-extrabold">{targetMode === "completion_loyalty" ? loyaltyTargets.length : targets.length}</p>
          <p className="mt-1 text-xs leading-4">
            {targetMode === "completion_loyalty"
              ? `${gbp(loyaltyTargets.reduce((sum, row) => sum + num(row.suggested_reward_gbp), 0))} reward-ready`
              : `${gbp(targets.reduce((sum, row) => sum + num(row.remaining_gbp), 0))} visible remaining`}
          </p>
        </div>
        <div className="rounded-2xl border border-sky-200 bg-sky-50 p-3 text-sky-900 shadow-sm">
          <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">Selected target</p>
          <p className="mt-1 text-2xl font-extrabold">{gbp(selectedPrimaryTotal)}</p>
          <p className="mt-1 text-xs leading-4">{targetMode === "completion_loyalty" ? (selectedLoyaltyTarget ? "1 reward target selected" : "No reward target") : `${selectedTargetIds.length} charge record(s) selected`}</p>
        </div>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-amber-900 shadow-sm">
          <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">Residual input</p>
          <p className="mt-1 text-2xl font-extrabold">{gbp(residualAmount)}</p>
          <p className="mt-1 text-xs leading-4">{loyaltyModeNeedsTarget ? "Disabled until a loyalty target is selected" : residualLabel(residualType)}</p>
        </div>
        <div className={`rounded-2xl border p-3 shadow-sm ${exact ? "border-emerald-200 bg-emerald-50 text-emerald-900" : gap >= 0 ? "border-amber-200 bg-amber-50 text-amber-900" : "border-rose-200 bg-rose-50 text-rose-900"}`}>
          <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">Gap</p>
          <p className="mt-1 text-2xl font-extrabold">{gbp(Math.abs(gap))}</p>
          <p className="mt-1 text-xs leading-4">{exact ? "Ready / balanced" : gap > 0 ? "Still unexplained" : "Over-selected"}</p>
        </div>
      </section>

      <section className="grid gap-4 xl:grid-cols-[1fr_1.2fr]">
        <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <h2 className="text-xl font-semibold">1. Select one main bank line</h2>
          <p className="mt-1 border-b border-slate-100 pb-3 text-sm text-slate-500">Click a bank line. The floating bar stays visible while you match.</p>
          <div className="mt-4 grid gap-3">
            {lines.map((line) => {
              const id = text(line.statement_line_id);
              const residual = residualByLine.get(id) ?? 0;
              const remaining = safeAvailable(line, residual);
              return (
                <button key={id} type="button" onClick={() => setSelectedLineId(id)} className={`rounded-2xl border p-4 text-left shadow-sm ${cardClass(id === selectedLineId, "bank")}`}>
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="text-lg font-bold text-slate-950">{short(line.reference_raw, 80)}</p>
                      <p className="mt-1 text-sm text-slate-600">{text(line.statement_date)} · {text(line.direction).toUpperCase()} · {text(line.source_bank).toUpperCase()}</p>
                    </div>
                    <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{remaining <= 0.01 ? "balanced" : cleanUiText(text(line.match_status))}</span>
                  </div>
                  <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-4">
                    <p>Amount <span className="font-bold text-slate-950">{gbp(line.amount_gbp)}</span></p>
                    <p>Shipper charges <span className="font-bold text-slate-950">{gbp(line.allocated_gbp)}</span></p>
                    <p>FX/fee/hold <span className="font-bold text-slate-950">{gbp(residual)}</span></p>
                    <p>Available <span className="font-bold text-slate-950">{gbp(remaining)}</span></p>
                  </div>
                </button>
              );
            })}
          </div>
        </div>

        {targetMode === "completion_loyalty" ? (
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <h2 className="text-xl font-semibold">2. Select one loyalty reward target</h2>
            <p className="mt-1 border-b border-slate-100 pb-3 text-sm text-slate-500">Select a clean completed reward-ready order. This reserves the main-bank OUT only. Pair the DVA/virtual-card IN before release.</p>
            <div className="mt-4 grid gap-3">
              {loyaltyTargets.length === 0 ? (
                <p className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm font-semibold text-slate-600">No completion loyalty targets are ready for main-bank OUT reservation.</p>
              ) : null}
              {loyaltyTargets.map((target) => {
                const id = text(target.order_id);
                const selected = id === selectedLoyaltyOrderId;
                return (
                  <button key={id} type="button" onClick={() => setSelectedLoyaltyOrderId(id)} className={`rounded-2xl border p-4 text-left shadow-sm transition hover:border-emerald-300 hover:bg-emerald-50 ${cardClass(selected, "target")}`}>
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-bold text-slate-950">{short(target.order_ref, 80)}</p>
                        <p className="mt-1 text-sm text-slate-600">{short(target.importer_name, 72)}</p>
                      </div>
                      <span className="rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-800">Reward-ready</span>
                    </div>
                    <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-3">
                      <p>Qualifying net <span className="font-bold text-slate-950">{gbp(target.qualifying_net_spend_gbp)}</span></p>
                      <p>Reward <span className="font-bold text-slate-950">{gbp(target.suggested_reward_gbp)}</span></p>
                      <p>Status <span className="font-bold text-slate-950">{short(target.target_status, 30)}</span></p>
                    </div>
                  </button>
                );
              })}
            </div>
          </div>
        ) : (
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <h2 className="text-xl font-semibold">2. Tick shipper charge record(s)</h2>
            <p className="mt-1 border-b border-slate-100 pb-3 text-sm text-slate-500">Tick one or more approved shipper charge records for the selected bank line.</p>
            <div className="mt-4 grid gap-3">
              {targets.map((target) => {
                const id = text(target.shipping_document_id);
                const selected = selectedTargetIds.includes(id);
                return (
                  <label key={id} className={`block cursor-pointer rounded-2xl border p-4 shadow-sm transition hover:border-emerald-300 hover:bg-emerald-50 ${cardClass(selected, "target")}`}>
                    <div className="flex items-start gap-3">
                      <input className="mt-1 h-4 w-4 rounded border-slate-300" type="checkbox" checked={selected} onChange={() => toggleTarget(id)} />
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-start justify-between gap-3">
                          <div>
                            <p className="text-lg font-bold text-slate-950">{short(target.shipper_invoice_ref, 80)}</p>
                            <p className="mt-1 text-sm text-slate-600">{text(target.shipper_name)} · Approved charge record</p>
                          </div>
                          <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{cleanUiText(text(target.target_status))}</span>
                        </div>
                        <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-3">
                          <p>Amount <span className="font-bold text-slate-950">{gbp(target.amount_gbp)}</span></p>
                          <p>Matched <span className="font-bold text-slate-950">{gbp(target.allocated_gbp)}</span></p>
                          <p>Remaining <span className="font-bold text-slate-950">{gbp(target.remaining_gbp)}</span></p>
                        </div>
                        <p className="mt-2 break-all text-xs text-slate-500">Accounting document: {short(target.sage_purchase_invoice_id, 42)}</p>
                      </div>
                    </div>
                  </label>
                );
              })}
            </div>
          </div>
        )}
      </section>

      <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
        <h2 className="text-xl font-semibold">Existing residuals</h2>
        <p className="mt-2 text-sm text-slate-600">FX/payment: {gbp(residualByType.get("fx_card_difference") ?? 0)} · Bank fee: {gbp(residualByType.get("bank_fee") ?? 0)} · Hold: {gbp(residualByType.get("unmatched_hold") ?? 0)}</p>
      </section>

      <div className="fixed inset-x-0 bottom-0 z-40 px-4 pb-3 sm:px-6 lg:px-8">
        <div className="mx-auto grid max-w-7xl gap-3 rounded-t-3xl border border-slate-200 bg-white/95 p-3 shadow-[0_-10px_30px_rgba(15,23,42,0.12)] backdrop-blur lg:grid-cols-[minmax(0,1fr)_minmax(0,34rem)] lg:items-end">
          <div className="min-w-0 space-y-1 text-sm text-slate-700">
            <p className="font-bold text-slate-950">Bank selected: {selectedLine ? short(selectedLine.reference_raw, 54) : "none"} · available {gbp(selectedLineAvailable)}</p>
            <p>{targetMode === "completion_loyalty" ? `Loyalty target selected: ${selectedLoyaltyTarget ? short(selectedLoyaltyTarget.order_ref, 42) : "none"} · ${gbp(selectedLoyaltyAmount)}` : `Shipper charges selected: ${selectedTargetIds.length} charge record(s) · ${gbp(selectedTargetTotal)}`}</p>
            <p>Residual selected: {loyaltyModeNeedsTarget ? "disabled until a loyalty target is selected" : `${gbp(residualAmount)} · ${residualLabel(residualType)}`}</p>
            <p className="font-bold text-slate-950">Gap: {gbp(gap)}</p>
            <p className="text-xs font-semibold text-amber-700">{loyaltyModeNeedsTarget ? "Select a clean loyalty reward target before reserving the main-bank OUT or recording any residual." : exact ? (targetMode === "completion_loyalty" ? "Balanced — ready to reserve the main-bank OUT. DVA/virtual-card IN pairing is still required before release." : "Balanced — ready to submit target and/or residual matches.") : gap > 0 ? "Still has unexplained amount. Add residual or select a larger target." : "Over-selected. Reduce target/residual."}</p>
          </div>

          <div className="grid min-w-0 gap-2 sm:grid-cols-2 lg:w-full">
            {targetMode === "completion_loyalty" ? (
              <form action={matchMainBankLineToCompletionLoyaltyAction} className="grid min-w-0 gap-2">
                <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
                <input type="hidden" name="order_id" value={selectedLoyaltyOrderId} />
                <input type="hidden" name="reward_amount_gbp" value={selectedLoyaltyAmount > 0 ? selectedLoyaltyAmount.toFixed(2) : ""} />
                <input type="hidden" name="notes" value="Main-bank OUT reserved for completion loyalty reward. Destination DVA/virtual-card IN must be paired before release." />
                <button type="submit" disabled={!canConfirmLoyalty} className="w-full rounded-xl bg-sky-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500">Reserve loyalty funding OUT</button>
              </form>
            ) : (
              <form action={allocateMainBankLineToShipperApAction} className="grid min-w-0 gap-2">
                <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
                {selectedTargetIds.map((id) => <input key={id} type="hidden" name="shipping_document_id" value={id} />)}
                <input type="hidden" name="notes" value="Main bank payment matched to posted shipper AP invoice(s)." />
                <button type="submit" disabled={!canConfirmAp} className="w-full rounded-xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500">Confirm shipper charge match</button>
              </form>
            )}

            <form action={allocateMainBankFxFeeAction} className="grid min-w-0 gap-2">
              <input type="hidden" name="target" value={targetMode} />
              <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
              <select className="w-full min-w-0 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100 disabled:text-slate-400" name="residual_allocation_type" value={residualType} onChange={(event) => setResidualType(event.target.value)} disabled={loyaltyModeNeedsTarget}>
                <option value="fx_card_difference">FX/payment variance</option>
                <option value="bank_fee">Bank fee</option>
              </select>
              <input className="w-full min-w-0 rounded-xl border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100 disabled:text-slate-400" name="residual_gbp_amount" value={loyaltyModeNeedsTarget ? "" : manualResidual || (residualAmount > 0 ? residualAmount.toFixed(2) : "")} onChange={(event) => setManualResidual(event.target.value)} placeholder={loyaltyModeNeedsTarget ? "Select loyalty target first" : "Residual amount"} disabled={loyaltyModeNeedsTarget} />
              <input type="hidden" name="notes" value="Main-bank residual allocated separately from selected target." />
              <button type="submit" disabled={!canConfirmResidual} className="w-full rounded-xl bg-amber-700 px-4 py-2 text-sm font-bold text-white disabled:bg-slate-200 disabled:text-slate-500">Save FX/payment or fee residual</button>
            </form>
          </div>
        </div>
      </div>
    </div>
  );
}
