"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

const vatLinks = [
  {
    step: "1",
    title: "VAT workbench",
    href: "/internal/accounting-vat",
    description: "VAT runs, source facts, blockers, journal queue status and Sage coverage controls.",
  },
  {
    step: "2",
    title: "Sage VAT diagnostics",
    href: "/internal/accounting-vat/sage-diagnostics",
    description: "Sage natural extraction, document status audit, included/excluded counts and Box 1/4/6/7 checks.",
  },
  {
    step: "3",
    title: "Platform VAT overlay",
    href: "/internal/accounting-vat/platform-overlay",
    description: "Read-only statutory overlay for prepayment Box 6, anti-duplicate Box 6 and export evidence Box 1 rules.",
  },
  {
    step: "4",
    title: "Accounting command centre",
    href: "/internal/accounting-command-centre",
    description: "Return here before posting. Sage posting follows only after extraction and platform overlay tie.",
  },
];

export default function InternalTemplate({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const showVatQuickLinks = pathname === "/internal" || pathname === "/internal/";

  return (
    <>
      {showVatQuickLinks ? (
        <div className="bg-slate-50 px-6 pt-8 text-slate-950">
          <section className="mx-auto max-w-7xl rounded-3xl border border-amber-200 bg-white p-5 shadow-sm">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p className="text-xs font-bold uppercase tracking-[0.22em] text-amber-600">Start here for VAT testing</p>
                <h2 className="mt-2 text-2xl font-semibold tracking-tight">VAT return and Sage coverage workflow</h2>
                <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                  Move from VAT run control to Sage natural extraction, then platform statutory overlay. Do not move to Sage journal posting until Sage extraction and platform overlay both tie.
                </p>
              </div>
              <Link href="/internal/accounting-vat" className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-amber-800">
                Open VAT workbench →
              </Link>
            </div>

            <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
              {vatLinks.map((link) => (
                <Link
                  key={`${link.step}-${link.href}`}
                  href={link.href}
                  className="rounded-2xl border border-slate-200 bg-slate-50 p-4 transition hover:border-amber-300 hover:bg-amber-50"
                >
                  <div className="flex items-center gap-2">
                    <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold text-amber-700 ring-1 ring-amber-200">
                      {link.step}
                    </span>
                    <h3 className="font-semibold text-slate-950">{link.title}</h3>
                  </div>
                  <p className="mt-2 text-xs leading-5 text-slate-600">{link.description}</p>
                </Link>
              ))}
            </div>
          </section>
        </div>
      ) : null}
      {children}
    </>
  );
}
