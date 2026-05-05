"use client";

import { useLayoutEffect } from "react";

function moneyPair(text: string) {
  const match = text.match(/Allocated\s+(£\s*[\d,]+(?:\.\d{1,2})?)\s*·\s*Remaining\s+(£\s*[\d,]+(?:\.\d{1,2})?)/i);
  if (!match) return null;
  return { used: match[1].replace(/\s+/g, ""), open: match[2].replace(/\s+/g, "") };
}

function enhanceBalanceChips() {
  const anchors = Array.from(
    document.querySelectorAll<HTMLAnchorElement>('a[href*="/internal/dva-reconciliation/workspace?"][href*="line_id"]')
  );

  for (const anchor of anchors) {
    if (anchor.dataset.balanceChipsEnhanced === "true") continue;
    const paragraphs = Array.from(anchor.querySelectorAll<HTMLParagraphElement>("p"));
    const balanceParagraph = paragraphs.find((paragraph) =>
      /Allocated\s+£[\d,.]+\s*·\s*Remaining\s+£[\d,.]+/i.test(paragraph.innerText)
    );

    if (!balanceParagraph) continue;
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
