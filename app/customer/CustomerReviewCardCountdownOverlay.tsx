"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

type ReviewCardRow = {
  order_id: string;
  customer_review_path: string;
  expires_at: string;
};

const OVERLAY_ATTR = "data-customer-review-countdown";

function remainingLabel(expiresAt: string) {
  const remainingMs = new Date(expiresAt).getTime() - Date.now();
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) return null;

  const totalMinutes = Math.ceil(remainingMs / 60_000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;

  if (hours > 0) return `${hours}h ${minutes}m left`;
  return `${minutes}m left`;
}

function orderIdFromHref(href: string | null) {
  const match = String(href ?? "").match(/^\/customer\/orders\/([^/]+)\/operations(?:\?.*)?$/);
  return match?.[1] ?? null;
}

export default function CustomerReviewCardCountdownOverlay() {
  const pathname = usePathname();

  useEffect(() => {
    if (pathname !== "/customer") return;

    const supabase = createClient();
    let cancelled = false;
    let intervalId: number | null = null;
    let refreshTimeoutId: number | null = null;

    async function load() {
      const { data, error } = await supabase.rpc("customer_dashboard_review_cards_v1");
      if (cancelled || error) return;

      const reviewByOrder = new Map(
        ((data ?? []) as ReviewCardRow[]).map((row) => [row.order_id, row])
      );

      function render() {
        document.querySelectorAll(`[${OVERLAY_ATTR}]`).forEach((node) => node.remove());

        let earliestExpiry = Number.POSITIVE_INFINITY;
        const orderLinks = Array.from(
          document.querySelectorAll<HTMLAnchorElement>('a[href^="/customer/orders/"][href*="/operations"]')
        );

        for (const link of orderLinks) {
          const orderId = orderIdFromHref(link.getAttribute("href"));
          if (!orderId) continue;

          const review = reviewByOrder.get(orderId);
          if (!review) continue;

          const label = remainingLabel(review.expires_at);
          if (!label) continue;

          const expiryMs = new Date(review.expires_at).getTime();
          if (Number.isFinite(expiryMs)) earliestExpiry = Math.min(earliestExpiry, expiryMs);

          const badge = document.createElement("div");
          badge.setAttribute(OVERLAY_ATTR, "true");
          badge.className =
            "mt-2 rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-black text-sky-900";
          badge.textContent = `Review items before shipment · ${label}`;

          const desktopRow = link.closest("tr");
          if (desktopRow) {
            const statusCell = desktopRow.querySelector<HTMLTableCellElement>("td:nth-child(7)");
            (statusCell ?? link.parentElement)?.appendChild(badge);
          } else {
            link.appendChild(badge);
          }
        }

        if (refreshTimeoutId !== null) window.clearTimeout(refreshTimeoutId);
        if (Number.isFinite(earliestExpiry)) {
          refreshTimeoutId = window.setTimeout(() => window.location.reload(), Math.max(earliestExpiry - Date.now() + 1_000, 1_000));
        }
      }

      render();
      intervalId = window.setInterval(render, 60_000);
    }

    void load();

    return () => {
      cancelled = true;
      if (intervalId !== null) window.clearInterval(intervalId);
      if (refreshTimeoutId !== null) window.clearTimeout(refreshTimeoutId);
      document.querySelectorAll(`[${OVERLAY_ATTR}]`).forEach((node) => node.remove());
    };
  }, [pathname]);

  return null;
}
