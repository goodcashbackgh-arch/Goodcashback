"use client";

import { useEffect } from "react";

function round2(value: number) {
  return Math.round(value * 100) / 100;
}

function toMoney(value: number) {
  return round2(value).toFixed(2);
}

function parseMoney(value: string | null | undefined) {
  const parsed = Number(String(value ?? "").replace(/[^0-9.-]/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function splitByRate(gross: number, rate: number) {
  if (rate <= 0) return { net: gross, vat: 0 };
  const net = round2(gross / (1 + rate / 100));
  return { net, vat: round2(gross - net) };
}

function taxLabel(rate: number) {
  if (rate === 20) return "20% standard";
  if (rate === 5) return "5% reduced";
  return "0% zero/exempt";
}

function taxId(rate: number) {
  if (rate === 20) return "STANDARD_20";
  if (rate === 5) return "REDUCED_5";
  return "ZERO_0";
}

export default function AccountingGridCalculator() {
  useEffect(() => {
    function recalcFromRate(row: HTMLElement) {
      const gross = parseMoney(row.dataset.gross);
      const rateInput = row.querySelector<HTMLSelectElement | HTMLInputElement>("[data-vat-rate]");
      const netInput = row.querySelector<HTMLInputElement>("[data-net]");
      const vatInput = row.querySelector<HTMLInputElement>("[data-vat]");
      const taxLabelInput = row.querySelector<HTMLInputElement>("[data-tax-label]");
      const taxIdInput = row.querySelector<HTMLInputElement>("[data-tax-id]");
      if (!rateInput || !netInput || !vatInput) return;

      const rate = Number(rateInput.value || 0);
      const { net, vat } = splitByRate(gross, rate);
      netInput.value = toMoney(net);
      vatInput.value = toMoney(vat);
      if (taxLabelInput) taxLabelInput.value = taxLabel(rate);
      if (taxIdInput) taxIdInput.value = taxId(rate);
    }

    function recalcFromNet(row: HTMLElement) {
      const gross = parseMoney(row.dataset.gross);
      const netInput = row.querySelector<HTMLInputElement>("[data-net]");
      const vatInput = row.querySelector<HTMLInputElement>("[data-vat]");
      if (!netInput || !vatInput) return;

      const net = Math.min(Math.max(parseMoney(netInput.value), 0), gross);
      netInput.value = toMoney(net);
      vatInput.value = toMoney(gross - net);
    }

    function recalcFromVat(row: HTMLElement) {
      const gross = parseMoney(row.dataset.gross);
      const netInput = row.querySelector<HTMLInputElement>("[data-net]");
      const vatInput = row.querySelector<HTMLInputElement>("[data-vat]");
      if (!netInput || !vatInput) return;

      const vat = Math.min(Math.max(parseMoney(vatInput.value), 0), gross);
      vatInput.value = toMoney(vat);
      netInput.value = toMoney(gross - vat);
    }

    function applyDefaults() {
      const nominal = (document.querySelector<HTMLInputElement>("[data-bulk-nominal]")?.value ?? "").trim();
      const sageLedger = (document.querySelector<HTMLInputElement>("[data-bulk-sage-ledger]")?.value ?? "").trim();
      const rate = document.querySelector<HTMLSelectElement>("[data-bulk-vat-rate]")?.value ?? "20";

      document.querySelectorAll<HTMLElement>("[data-accounting-row]").forEach((row) => {
        const nominalInput = row.querySelector<HTMLInputElement>("[data-nominal]");
        const sageInput = row.querySelector<HTMLInputElement>("[data-sage-ledger]");
        const rateInput = row.querySelector<HTMLSelectElement | HTMLInputElement>("[data-vat-rate]");
        if (nominalInput && nominal) {
          nominalInput.value = nominal;
          nominalInput.dispatchEvent(new Event("change", { bubbles: true }));
        }
        if (sageInput && sageLedger) {
          sageInput.value = sageLedger;
          sageInput.dispatchEvent(new Event("change", { bubbles: true }));
        }
        if (rateInput) {
          rateInput.value = rate;
          rateInput.dispatchEvent(new Event("change", { bubbles: true }));
        }
      });
    }

    function handleRowUpdate(event: Event) {
      const control = event.target instanceof Element ? event.target : null;
      const row = control?.closest<HTMLElement>("[data-accounting-row]");
      if (!control || !row) return;

      if (control.matches("[data-vat-rate]")) recalcFromRate(row);
      if (control.matches("[data-net]")) recalcFromNet(row);
      if (control.matches("[data-vat]")) recalcFromVat(row);
    }

    function handleClick(event: MouseEvent) {
      const target = event.target instanceof Element ? event.target : null;
      if (target?.closest("[data-apply-bulk-defaults]")) applyDefaults();
    }

    document.addEventListener("change", handleRowUpdate);
    document.addEventListener("blur", handleRowUpdate, true);
    document.addEventListener("click", handleClick);

    return () => {
      document.removeEventListener("change", handleRowUpdate);
      document.removeEventListener("blur", handleRowUpdate, true);
      document.removeEventListener("click", handleClick);
    };
  }, []);

  return null;
}
