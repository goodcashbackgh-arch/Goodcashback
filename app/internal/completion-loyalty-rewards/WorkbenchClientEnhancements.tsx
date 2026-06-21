"use client";

import { useEffect } from "react";

function parseNumber(value: string | undefined) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function formatAmount(value: number) {
  return Math.max(0, Math.round(value * 100) / 100).toFixed(2);
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
