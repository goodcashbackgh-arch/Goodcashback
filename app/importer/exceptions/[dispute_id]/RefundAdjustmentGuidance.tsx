"use client";

import { type ReactNode, useEffect, useState } from "react";

type Mode = "credit_note" | "refund_proof_no_credit_note" | "no_document" | "";

export default function RefundAdjustmentGuidance({ children }: { children: ReactNode }) {
  const [mode, setMode] = useState<Mode>("");

  useEffect(() => {
    const resolveMode = () => {
      const activeMode = document.querySelector<HTMLInputElement>(
        'form input[name="document_mode"]',
      )?.value;

      if (["credit_note", "refund_proof_no_credit_note", "no_document"].includes(activeMode ?? "")) {
        setMode(activeMode as Mode);
      } else {
        setMode("");
      }
    };

    resolveMode();
    const observer = new MutationObserver(resolveMode);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return (
    <>
      {mode === "credit_note" ? (
        <div className="mx-auto mt-4 max-w-7xl px-6">
          <div className="rounded-2xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950 shadow-sm">
            <p className="font-semibold">Formal credit-note adjustment rule</p>
            <p className="mt-1 leading-6">
              Enter the full face total printed on the credit note. Leave the delivery and discount adjustment fields blank when those amounts appear anywhere on the credit note or are already included in its total. Use those fields only for a genuine additional refund outside the uploaded credit note.
            </p>
          </div>
        </div>
      ) : null}
      {children}
    </>
  );
}
