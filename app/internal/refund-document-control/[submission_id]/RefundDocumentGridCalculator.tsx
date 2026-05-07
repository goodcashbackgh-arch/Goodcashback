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

function closestRow(element: Element | null) {
  return element?.closest("tr") ?? null;
}

function getLineIdFromName(name: string | null | undefined, prefix: string) {
  if (!name?.startsWith(prefix)) return "";
  return name.slice(prefix.length);
}

function findGross(row: HTMLTableRowElement | null) {
  if (!row) return 0;
  const cells = Array.from(row.querySelectorAll("td"));
  const grossCell = cells.find((cell) => cell.textContent?.includes("£"));
  return parseMoney(grossCell?.textContent ?? "0");
}

export default function RefundDocumentGridCalculator() {
  useEffect(() => {
    const rateSelects = Array.from(document.querySelectorAll<HTMLSelectElement>('select[name^="vat_rate_percent_"]'));
    const netInputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[name^="net_amount_gbp_"]'));
    const vatInputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[name^="vat_amount_gbp_"]'));

    function getInputs(lineId: string) {
      return {
        rateInput: document.querySelector<HTMLSelectElement>(`select[name="vat_rate_percent_${lineId}"]`),
        netInput: document.querySelector<HTMLInputElement>(`input[name="net_amount_gbp_${lineId}"]`),
        vatInput: document.querySelector<HTMLInputElement>(`input[name="vat_amount_gbp_${lineId}"]`),
        taxLabelInput: document.querySelector<HTMLInputElement>(`input[name="tax_rate_label_${lineId}"]`),
        taxIdInput: document.querySelector<HTMLInputElement>(`input[name="tax_rate_id_${lineId}"]`),
      };
    }

    function recalcFromRate(lineId: string) {
      const { rateInput, netInput, vatInput, taxLabelInput, taxIdInput } = getInputs(lineId);
      if (!rateInput || !netInput || !vatInput) return;
      const gross = findGross(closestRow(rateInput));
      const rate = Number(rateInput.value || 0);
      const { net, vat } = splitByRate(gross, rate);
      netInput.value = toMoney(net);
      vatInput.value = toMoney(vat);
      if (taxLabelInput) taxLabelInput.value = taxLabel(rate);
      if (taxIdInput) taxIdInput.value = taxId(rate);
    }

    function recalcFromNet(lineId: string) {
      const { netInput, vatInput } = getInputs(lineId);
      if (!netInput || !vatInput) return;
      const gross = findGross(closestRow(netInput));
      const net = Math.min(Math.max(parseMoney(netInput.value), 0), gross);
      netInput.value = toMoney(net);
      vatInput.value = toMoney(gross - net);
    }

    function recalcFromVat(lineId: string) {
      const { netInput, vatInput } = getInputs(lineId);
      if (!netInput || !vatInput) return;
      const gross = findGross(closestRow(vatInput));
      const vat = Math.min(Math.max(parseMoney(vatInput.value), 0), gross);
      vatInput.value = toMoney(vat);
      netInput.value = toMoney(gross - vat);
    }

    const cleanups: Array<() => void> = [];

    rateSelects.forEach((input) => {
      const lineId = getLineIdFromName(input.name, "vat_rate_percent_");
      if (!lineId) return;
      const handler = () => recalcFromRate(lineId);
      input.addEventListener("change", handler);
      cleanups.push(() => input.removeEventListener("change", handler));
    });

    netInputs.forEach((input) => {
      const lineId = getLineIdFromName(input.name, "net_amount_gbp_");
      if (!lineId) return;
      const handler = () => recalcFromNet(lineId);
      input.addEventListener("change", handler);
      input.addEventListener("blur", handler);
      cleanups.push(() => {
        input.removeEventListener("change", handler);
        input.removeEventListener("blur", handler);
      });
    });

    vatInputs.forEach((input) => {
      const lineId = getLineIdFromName(input.name, "vat_amount_gbp_");
      if (!lineId) return;
      const handler = () => recalcFromVat(lineId);
      input.addEventListener("change", handler);
      input.addEventListener("blur", handler);
      cleanups.push(() => {
        input.removeEventListener("change", handler);
        input.removeEventListener("blur", handler);
      });
    });

    return () => cleanups.forEach((cleanup) => cleanup());
  }, []);

  return null;
}
