"use client";

import { useEffect } from "react";
import { useSearchParams } from "next/navigation";

export default function ReturnTasksRedirect() {
  const searchParams = useSearchParams();

  useEffect(() => {
    const query = searchParams.toString();
    window.location.replace(`/shipper/return-actions${query ? `?${query}` : ""}`);
  }, [searchParams]);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-3xl rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
        <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
        <h1 className="mt-2 text-2xl font-semibold tracking-tight">Opening return actions…</h1>
        <p className="mt-2 text-sm leading-6 text-slate-600">Return tasks has been renamed to return actions. Redirecting now.</p>
      </div>
    </main>
  );
}
