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

export default function AccountingGridCalculator() {
  useEffect(() => {
    const rows = Array.from(document.querySelectorAll<HTMLElement>("[data-accounting-row]"));

    function recalcFromRate(row: HTMLElement) {
      const gross = parseMoney(row.dataset.gross);
      const rateInput = row.querySelector<HTMLSelectElement | HTMLInputElement>("[data-vat-rate]");
      const netInput = row.querySelector<HTMLInputElement>("[data-net]");
      const vatInput = row.querySelector<HTMLInputElement>("[data-vat]");
      if (!rateInput || !netInput || !vatInput) return;

      const { net, vat } = splitByRate(gross, Number(rateInput.value || 0));
      netInput.value = toMoney(net);
      vatInput.value = toMoney(vat);
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

    const cleanups: Array<() => void> = [];

    rows.forEach((row) => {
      const rateInput = row.querySelector<HTMLSelectElement | HTMLInputElement>("[data-vat-rate]");
      const netInput = row.querySelector<HTMLInputElement>("[data-net]");
      const vatInput = row.querySelector<HTMLInputElement>("[data-vat]");

      if (rateInput) {
        const handler = () => recalcFromRate(row);
        rateInput.addEventListener("change", handler);
        cleanups.push(() => rateInput.removeEventListener("change", handler));
      }

      if (netInput) {
        const handler = () => recalcFromNet(row);
        netInput.addEventListener("change", handler);
        netInput.addEventListener("blur", handler);
        cleanups.push(() => {
          netInput.removeEventListener("change", handler);
          netInput.removeEventListener("blur", handler);
        });
      }

      if (vatInput) {
        const handler = () => recalcFromVat(row);
        vatInput.addEventListener("change", handler);
        vatInput.addEventListener("blur", handler);
        cleanups.push(() => {
          vatInput.removeEventListener("change", handler);
          vatInput.removeEventListener("blur", handler);
        });
      }
    });

    return () => cleanups.forEach((cleanup) => cleanup());
  }, []);

  return null;
}
