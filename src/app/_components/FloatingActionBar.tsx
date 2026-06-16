"use client";

import type { ReactNode } from "react";
import { useEffect, useState } from "react";

type FloatingActionBarProps = {
  children: ReactNode;
  hideWhenVisibleId?: string;
  className?: string;
  innerClassName?: string;
};

export const SHIPMENT_FLOATING_ACTION_HIDE_SENTINEL_ID = "shipment-floating-actions-hide-sentinel";

export function FloatingActionBar({
  children,
  hideWhenVisibleId = SHIPMENT_FLOATING_ACTION_HIDE_SENTINEL_ID,
  className = "fixed inset-x-0 bottom-4 z-40 flex justify-center px-4 print:hidden",
  innerClassName = "flex max-w-4xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-slate-200 bg-white/95 p-3 shadow-lg backdrop-blur",
}: FloatingActionBarProps) {
  const [hidden, setHidden] = useState(false);

  useEffect(() => {
    const target =
      document.getElementById(hideWhenVisibleId) ??
      document.querySelector<HTMLElement>("[data-floating-actions-hide-sentinel]") ??
      document.querySelector<HTMLElement>("main section:last-of-type");

    if (!target || typeof IntersectionObserver === "undefined") {
      setHidden(false);
      return;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        setHidden(entry.isIntersecting);
      },
      { threshold: 0.01 },
    );

    observer.observe(target);

    return () => observer.disconnect();
  }, [hideWhenVisibleId]);

  return (
    <div
      className={`${className} transition duration-150 ${
        hidden ? "pointer-events-none translate-y-4 opacity-0" : "opacity-100"
      }`}
      aria-hidden={hidden}
    >
      <div className={innerClassName}>{children}</div>
    </div>
  );
}
