"use client";

import { useEffect } from "react";

function parseMoney(raw: string | null | undefined) {
  if (!raw) return 0;
  const cleaned = raw.replace(/[^0-9.\-]/g, "");
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(value || 0);
}

function firstMoneyAfter(label: string, haystack: string) {
  const index = haystack.toLowerCase().indexOf(label.toLowerCase());
  if (index < 0) return 0;
  const slice = haystack.slice(index, index + 180);
  const match = slice.match(/£\s*[-0-9,]+(?:\.\d{1,2})?/);
  return parseMoney(match?.[0]);
}

function selectedOptionMoney(form: HTMLFormElement) {
  const select = form.querySelector<HTMLSelectElement>('select[name="top_up_statement_line_id"]');
  if (!select) return 0;
  const option = select.selectedOptions?.[0];
  const match = option?.textContent?.match(/£\s*[-0-9,]+(?:\.\d{1,2})?/);
  return parseMoney(match?.[0]);
}

function nearestArticleText(form: HTMLFormElement) {
  const article = form.closest("article");
  return article?.textContent || form.textContent || "";
}

function releaseMessage(form: HTMLFormElement) {
  const formData = new FormData(form);
  const isSingle = Boolean(formData.get("loyalty_match_id"));
  const isBulk = Boolean(formData.get("loyalty_match_ids"));
  const topUpLineId = String(formData.get("top_up_statement_line_id") || "");
  const articleText = nearestArticleText(form);
  const inRemaining = selectedOptionMoney(form) || firstMoneyAfter("DVA/card IN remaining", articleText);

  if (!topUpLineId || (!isSingle && !isBulk)) return null;

  const selectedAmount = isBulk
    ? firstMoneyAfter("Selected loyalty pot", articleText) || firstMoneyAfter("Source OUT", articleText)
    : firstMoneyAfter("Reserved OUT amount", articleText);

  const excess = Math.max(inRemaining - selectedAmount, 0);
  const excessPct = selectedAmount > 0 ? (excess / selectedAmount) * 100 : 0;
  const highRisk = isSingle && selectedAmount > 0 && (excess > 25 || excessPct > 10);
  const warning = highRisk
    ? [
        "HIGH-RISK SINGLE LOYALTY RELEASE",
        "",
        `Selected reward/source OUT: ${money(selectedAmount)}`,
        `Selected DVA/card IN remaining: ${money(inRemaining)}`,
        `Unconsumed IN balance after release: ${money(excess)} (${excessPct.toFixed(2)}%)`,
        "",
        "This may be the wrong same-importer top-up line. If this IN is intended to fund multiple rewards, cancel and use the funding-pot group instead.",
        "",
        "This release creates customer-available loyalty credit. Continue?",
      ]
    : [
        isBulk ? "Bulk loyalty funding-pot release" : "Single loyalty release",
        "",
        `Selected loyalty amount: ${money(selectedAmount)}`,
        inRemaining ? `Selected DVA/card IN remaining: ${money(inRemaining)}` : "Selected DVA/card IN: selected by staff",
        excess > 0 ? `Unconsumed IN balance after release: ${money(excess)}` : "Selected IN appears exact or fully consumed by this release.",
        "",
        "No loyalty FX is posted by this release. This action creates customer-available loyalty credit. Continue?",
      ];

  return warning.join("\n");
}

export default function ReleaseGuard() {
  useEffect(() => {
    function onSubmit(event: SubmitEvent) {
      const form = event.target;
      if (!(form instanceof HTMLFormElement)) return;
      const message = releaseMessage(form);
      if (!message) return;
      if (!window.confirm(message)) {
        event.preventDefault();
        event.stopPropagation();
      }
    }

    document.addEventListener("submit", onSubmit, true);
    return () => document.removeEventListener("submit", onSubmit, true);
  }, []);

  return null;
}
