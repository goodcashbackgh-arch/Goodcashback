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

const BOTTOM_HIDE_DISTANCE_PX = 180;

export function FloatingActionBar({
  children,
  hideWhenVisibleId = SHIPMENT_FLOATING_ACTION_HIDE_SENTINEL_ID,
  className = "fixed inset-x-0 bottom-4 z-40 flex justify-center px-4 print:hidden",
  innerClassName = "flex max-w-4xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-slate-200 bg-white/95 p-3 shadow-lg backdrop-blur",
}: FloatingActionBarProps) {
  const [hidden, setHidden] = useState(false);

  useEffect(() => {
    let sentinelHidden = false;

    const isNearBottom = () => {
      const doc = document.documentElement;
      const body = document.body;
      const scrollTop = window.scrollY || window.pageYOffset || doc.scrollTop || 0;
      const viewportHeight = window.innerHeight || doc.clientHeight || 0;
      const scrollHeight = Math.max(doc.scrollHeight, body?.scrollHeight ?? 0);

      return scrollHeight - (scrollTop + viewportHeight) <= BOTTOM_HIDE_DISTANCE_PX;
    };

    const applyHiddenState = () => {
      setHidden(sentinelHidden || isNearBottom());
    };

    const target =
      document.getElementById(hideWhenVisibleId) ??
      document.querySelector<HTMLElement>("[data-floating-actions-hide-sentinel]") ??
      document.querySelector<HTMLElement>("main section:last-of-type");

    const observer =
      target && typeof IntersectionObserver !== "undefined"
        ? new IntersectionObserver(
            ([entry]) => {
              sentinelHidden = entry.isIntersecting;
              applyHiddenState();
            },
            { threshold: 0.01 },
          )
        : null;

    if (target && observer) observer.observe(target);

    applyHiddenState();
    window.addEventListener("scroll", applyHiddenState, { passive: true });
    window.addEventListener("resize", applyHiddenState);

    return () => {
      observer?.disconnect();
      window.removeEventListener("scroll", applyHiddenState);
      window.removeEventListener("resize", applyHiddenState);
    };
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
