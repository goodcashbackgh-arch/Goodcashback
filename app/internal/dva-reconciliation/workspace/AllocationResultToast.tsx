"use client";

import { useEffect, useState } from "react";

export default function AllocationResultToast() {
  const [message, setMessage] = useState<{ tone: "success" | "error"; text: string } | null>(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const error = params.get("allocation_error");
    const success = params.get("allocation_success");

    if (!error && !success) return;

    if (error) {
      setMessage({ tone: "error", text: error });
    } else if (success) {
      setMessage({ tone: "success", text: success });
    }

    const url = new URL(window.location.href);
    url.searchParams.delete("allocation_error");
    url.searchParams.delete("allocation_success");
    window.history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
  }, []);

  if (!message) return null;

  const toneClasses =
    message.tone === "error"
      ? "border-rose-300 bg-rose-50 text-rose-900"
      : "border-emerald-300 bg-emerald-50 text-emerald-900";

  return (
    <div className="fixed left-4 right-4 top-4 z-50 mx-auto max-w-5xl">
      <div className={`rounded-2xl border px-4 py-3 text-sm font-semibold shadow-lg ${toneClasses}`}>
        {message.text}
      </div>
    </div>
  );
}
