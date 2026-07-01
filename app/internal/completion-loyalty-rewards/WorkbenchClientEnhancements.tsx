"use client";

import { useEffect } from "react";

function parseNumber(value: string | undefined) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function formatAmount(value: number) {
  return Math.max(0, Math.round(value * 100) / 100).toFixed(2);
}

function normalizeInternalDashboardBreadcrumb() {
  document.querySelectorAll<HTMLAnchorElement>('a[href="/internal"]').forEach((link) => {
    if (link.textContent?.trim() === "← Internal tools") {
      link.textContent = "← Internal dashboard";
    }
  });
}

function adoptInternalDashboardShell() {
  const main = document.querySelector("main");
  if (!main) return;

  main.className = "min-h-screen bg-slate-50 px-6 py-8 text-slate-950";

  Array.from(main.children).forEach((child) => {
    if (!(child instanceof HTMLElement)) return;
    child.classList.add("mx-auto", "max-w-7xl");
  });

  const header = Array.from(main.children).find((child): child is HTMLElement => {
    if (!(child instanceof HTMLElement)) return false;
    return child.querySelector("h1")?.textContent?.trim() === "Completion loyalty rewards";
  });

  if (!header) return;

  header.className = "mx-auto mb-6 max-w-7xl overflow-hidden rounded-3xl border border-sky-100 bg-white shadow-sm";

  if (!header.querySelector('[data-loyalty-dashboard-bar="true"]')) {
    const bar = document.createElement("div");
    bar.dataset.loyaltyDashboardBar = "true";
    bar.className = "h-2 bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300";
    header.prepend(bar);
  }

  const content = Array.from(header.children).find((child): child is HTMLElement => {
    if (!(child instanceof HTMLElement)) return false;
    return child.querySelector("h1")?.textContent?.trim() === "Completion loyalty rewards";
  });

  if (content) {
    content.className = "p-6";
  }

  const topRow = header.querySelector<HTMLDivElement>("div.p-6 > div");
  if (topRow) {
    topRow.className = "flex flex-wrap items-center justify-between gap-3";
  }

  const breadcrumb = header.querySelector<HTMLAnchorElement>('a[href="/internal"]');
  if (breadcrumb) {
    breadcrumb.className = "text-sm font-bold text-sky-700 hover:text-sky-900";
  }

  if (topRow && !topRow.querySelector('[data-loyalty-supplier-wallet-shortcut="true"]')) {
    const shortcut = document.createElement("a");
    shortcut.href = "/internal/completion-loyalty-rewards/supplier-wallet-payments";
    shortcut.dataset.loyaltySupplierWalletShortcut = "true";
    shortcut.className = "rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-2 text-sm font-bold text-emerald-800 hover:bg-emerald-100";
    shortcut.textContent = "Supplier wallet payments";
    topRow.appendChild(shortcut);
  }

  if (topRow && !topRow.querySelector('[data-loyalty-rejection-shortcut="true"]')) {
    const shortcut = document.createElement("a");
    shortcut.href = "/internal/completion-loyalty-rewards/rejections";
    shortcut.dataset.loyaltyRejectionShortcut = "true";
    shortcut.className = "rounded-xl border border-sky-200 bg-sky-50 px-4 py-2 text-sm font-bold text-sky-800 hover:bg-sky-100";
    shortcut.textContent = "Reject rewards →";
    topRow.appendChild(shortcut);
  }

  const h1 = header.querySelector("h1");
  if (h1) {
    h1.className = "mt-8 text-3xl font-semibold tracking-tight text-slate-950 sm:text-4xl";
  }

  const intro = h1?.nextElementSibling;
  if (intro instanceof HTMLElement) {
    intro.className = "mt-3 max-w-4xl text-sm leading-6 text-slate-600";
  }

  const signedIn = intro?.nextElementSibling;
  if (signedIn instanceof HTMLElement) {
    signedIn.className = "mt-4 rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700";
  }
}

function syncApprovalForm(form: HTMLFormElement, changedName: string) {
  if (form.dataset.syncingApproval === "true") return;

  const base = parseNumber(form.dataset.qualifyingNetSpend);
  if (!(base > 0)) return;

  const amount = form.querySelector<HTMLInputElement>('[name="approved_amount_gbp"]');
  const rate = form.querySelector<HTMLInputElement>('[name="reward_rate_pct"]');
  if (!amount || !rate) return;

  form.dataset.syncingApproval = "true";

  if (changedName === "approved_amount_gbp") {
    const approvedAmount = parseNumber(amount.value);
    if (approvedAmount > 0) rate.value = formatAmount((approvedAmount / base) * 100);
  }

  if (changedName === "reward_rate_pct") {
    const rewardRate = parseNumber(rate.value);
    if (rewardRate > 0) amount.value = formatAmount(base * (rewardRate / 100));
  }

  form.dataset.syncingApproval = "false";
}

function clearFundingProofValidity(form: HTMLFormElement) {
  const evidence = form.querySelector<HTMLInputElement>('[name="funding_evidence_ref"]');
  if (evidence) evidence.setCustomValidity("");
}

function validateFundingProof(form: HTMLFormElement, event: Event) {
  const dva = form.querySelector<HTMLInputElement>('[name="dva_statement_line_id"]');
  const evidence = form.querySelector<HTMLInputElement>('[name="funding_evidence_ref"]');

  if ((dva && dva.value.trim()) || (evidence && evidence.value.trim())) {
    if (evidence) evidence.setCustomValidity("");
    return;
  }

  event.preventDefault();
  if (evidence) {
    evidence.setCustomValidity("Funding proof required: enter a DVA statement line ID or funding evidence reference.");
    evidence.reportValidity();
  }
}

export function WorkbenchClientEnhancements() {
  useEffect(() => {
    adoptInternalDashboardShell();
    normalizeInternalDashboardBreadcrumb();

    const onInput = (event: Event) => {
      const target = event.target as HTMLInputElement | null;
      if (!target) return;

      const approvalForm = target.closest('[data-loyalty-approval-form="true"]') as HTMLFormElement | null;
      if (approvalForm && (target.name === "approved_amount_gbp" || target.name === "reward_rate_pct")) {
        approvalForm.dataset.lastEditedLoyaltyField = target.name;
        syncApprovalForm(approvalForm, target.name);
      }

      const fundingForm = target.closest('[data-funding-proof-form="true"]') as HTMLFormElement | null;
      if (fundingForm) clearFundingProofValidity(fundingForm);
    };

    const onSubmit = (event: Event) => {
      const form = event.target as HTMLFormElement | null;
      if (!form || !form.matches) return;

      if (form.matches('[data-loyalty-approval-form="true"]')) {
        syncApprovalForm(form, form.dataset.lastEditedLoyaltyField || "reward_rate_pct");
      }

      if (form.matches('[data-funding-proof-form="true"]')) {
        validateFundingProof(form, event);
      }
    };

    document.addEventListener("input", onInput, true);
    document.addEventListener("submit", onSubmit, true);

    return () => {
      document.removeEventListener("input", onInput, true);
      document.removeEventListener("submit", onSubmit, true);
    };
  }, []);

  return null;
}