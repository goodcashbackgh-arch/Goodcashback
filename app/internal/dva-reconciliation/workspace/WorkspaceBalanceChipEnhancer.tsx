"use client";

import { useLayoutEffect } from "react";

function moneyPair(text: string) {
  const match = text.match(/Allocated\s+(£\s*[\d,]+(?:\.\d{1,2})?)\s*·\s*Remaining\s+(£\s*[\d,]+(?:\.\d{1,2})?)/i);
  if (!match) return null;
  return { used: match[1].replace(/\s+/g, ""), open: match[2].replace(/\s+/g, "") };
}

function readableStatementText(value: string) {
  const original = value.trim();
  if (!original || /^no statement text$/i.test(original)) return original;

  let next = original
    .replace(/momoandgiptransfer/gi, "MOMO AND GIP TRANSFER")
    .replace(/banktowallet/gi, "Bank to Wallet")
    .replace(/medicalexpenses/gi, "medical expenses")
    .replace(/ocexpenses/gi, "OC expenses")
    .replace(/expenses/gi, " expenses ")
    .replace(/salaryfrom/gi, "salary from")
    .replace(/fromtrendy/gi, "from TRENDY")
    .replace(/to(eunice|dorothy|ian|jobyco|sharkninja)/gi, " to $1")
    .replace(/sharkninja/gi, "SharkNinja")
    .replace(/hennesmauritz/gi, "Hennes Mauritz")
    .replace(/([a-zA-Z])([0-9])/g, "$1 $2")
    .replace(/([0-9])([a-zA-Z])/g, "$1 $2")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/\s+/g, " ")
    .trim();

  if (next.length > 96) next = `${next.slice(0, 96).trim()}…`;
  return next;
}

function improveStatementDescription(anchor: HTMLAnchorElement, balanceParagraph: HTMLParagraphElement) {
  const paragraphs = Array.from(anchor.querySelectorAll<HTMLParagraphElement>("p"));
  const candidates = paragraphs.filter((paragraph) => paragraph !== balanceParagraph);

  const description = candidates.find((paragraph) => {
    const value = paragraph.innerText.trim();
    if (!value || /^\d{4}-\d{2}-\d{2}\s*·/i.test(value)) return false;
    if (/Allocated\s+£[\d,.]+\s*·\s*Remaining\s+£[\d,.]+/i.test(value)) return false;
    if (/^(balanced|unmatched|part|part allocated)$/i.test(value)) return false;
    return value.length > 8;
  });

  if (!description || description.dataset.statementTextEnhanced === "true") return;

  const readable = readableStatementText(description.innerText);
  if (!readable || readable === description.innerText.trim()) return;

  description.dataset.statementTextEnhanced = "true";
  description.dataset.originalStatementText = description.innerText.trim();
  description.innerText = readable;
  description.style.wordBreak = "normal";
  description.style.overflowWrap = "break-word";
  description.style.lineHeight = "1.35";
}

function enhanceBalanceChips() {
  const anchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id"]')
  );

  for (const anchor of anchors) {
    const paragraphs = Array.from(anchor.querySelectorAll<HTMLParagraphElement>("p"));
    const balanceParagraph = paragraphs.find((paragraph) =>
      /Allocated\s+£[\d,.]+\s*·\s*Remaining\s+£[\d,.]+/i.test(paragraph.innerText)
    );

    if (!balanceParagraph) continue;
    improveStatementDescription(anchor, balanceParagraph);

    if (anchor.dataset.balanceChipsEnhanced === "true") continue;
    const parsed = moneyPair(balanceParagraph.innerText);
    if (!parsed) continue;

    balanceParagraph.dataset.originalBalanceText = balanceParagraph.innerText;
    balanceParagraph.style.fontSize = "0";
    balanceParagraph.style.lineHeight = "0";
    balanceParagraph.style.margin = "0";
    balanceParagraph.style.height = "0";
    balanceParagraph.style.overflow = "hidden";

    const wrapper = document.createElement("div");
    wrapper.dataset.balanceChipBlock = "true";
    wrapper.className = "mt-3 grid grid-cols-2 gap-2";

    const used = document.createElement("div");
    used.className = "rounded-xl border border-slate-200 bg-slate-50 px-3 py-2";
    used.innerHTML = `<div class="text-[10px] font-bold uppercase tracking-wide text-slate-500">USED</div><div class="text-base font-extrabold text-slate-950">${parsed.used}</div>`;

    const open = document.createElement("div");
    open.className = "rounded-xl border border-amber-200 bg-amber-50 px-3 py-2";
    open.innerHTML = `<div class="text-[10px] font-bold uppercase tracking-wide text-amber-700">OPEN</div><div class="text-base font-extrabold text-amber-900">${parsed.open}</div>`;

    wrapper.appendChild(used);
    wrapper.appendChild(open);
    balanceParagraph.insertAdjacentElement("afterend", wrapper);
    anchor.dataset.balanceChipsEnhanced = "true";
  }
}

export default function WorkspaceBalanceChipEnhancer() {
  useLayoutEffect(() => {
    enhanceBalanceChips();

    const observer = new MutationObserver(() => enhanceBalanceChips());
    observer.observe(document.body, { childList: true, subtree: true });

    return () => observer.disconnect();
  }, []);

  return null;
}
