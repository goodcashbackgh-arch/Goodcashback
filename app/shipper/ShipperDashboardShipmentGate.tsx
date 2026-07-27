"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

type ShipmentCandidateRow = {
  tracking_submission_id: string | null;
};

type ReceiptDashboardRow = {
  order_id: string;
  tracking_submission_id: string | null;
  latest_receipt_status: string | null;
  in_active_shipment_yn: boolean | null;
};

type TrackingReviewState = {
  active_review_yn: boolean;
  review_link_id: string | null;
  review_expires_at: string | null;
};

function remainingLabel(milliseconds: number) {
  const totalMinutes = Math.max(0, Math.ceil(milliseconds / 60000));
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;

  if (hours > 0) return `${hours}h ${minutes}m remaining`;
  return `${minutes}m remaining`;
}

function trackingIdFromRow(row: HTMLTableRowElement) {
  const receiptLink = row.querySelector<HTMLAnchorElement>('a[href^="/shipper/package-receipts?tracking="]');
  if (!receiptLink) return null;

  try {
    return new URL(receiptLink.href).searchParams.get("tracking");
  } catch {
    return null;
  }
}

function replaceAction(
  row: HTMLTableRowElement,
  trackingId: string,
  candidateIds: Set<string>,
  dashboardByTrackingId: Map<string, ReceiptDashboardRow>,
  reviewStateByTrackingId: Map<string, TrackingReviewState>,
  now: number
) {
  const dashboardRow = dashboardByTrackingId.get(trackingId);
  const reviewState = reviewStateByTrackingId.get(trackingId);
  if (!dashboardRow || dashboardRow.latest_receipt_status !== "received_clean" || dashboardRow.in_active_shipment_yn) return;

  const existingAddLink = row.querySelector<HTMLAnchorElement>('a[href^="/shipper/shipments/new"]');
  const existingGate = row.querySelector<HTMLElement>("[data-shipment-review-gate]");
  const actionContainer = existingAddLink?.parentElement ?? existingGate?.parentElement;
  if (!actionContainer) return;

  if (candidateIds.has(trackingId)) {
    existingGate?.remove();
    if (existingAddLink) existingAddLink.hidden = false;
    return;
  }

  if (existingAddLink) existingAddLink.hidden = true;

  const deadlineMs = reviewState?.review_expires_at
    ? Date.parse(reviewState.review_expires_at)
    : Number.NaN;
  const activeReview = reviewState?.active_review_yn === true && Number.isFinite(deadlineMs) && now < deadlineMs;

  const gate = existingGate ?? document.createElement("span");
  gate.dataset.shipmentReviewGate = "true";
  gate.className = activeReview
    ? "rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-xs font-semibold text-amber-900"
    : "rounded-xl border border-slate-300 bg-slate-100 px-3 py-2 text-xs font-semibold text-slate-700";
  gate.textContent = activeReview
    ? `Customer review · ${remainingLabel(deadlineMs - now)}`
    : "Shipment blocked";
  gate.title = activeReview
    ? "This package becomes eligible after the active customer review closes, provided no other shipment blocker applies."
    : "The review window has ended, but another existing shipment control is still blocking this package.";

  if (!existingGate) actionContainer.appendChild(gate);
}

export default function ShipperDashboardShipmentGate() {
  const pathname = usePathname();
  const router = useRouter();

  useEffect(() => {
    if (pathname !== "/shipper") return;

    let cancelled = false;
    let refreshScheduled = false;
    const supabase = createClient();

    async function loadAndApply() {
      const [{ data: candidateData }, { data: dashboardData }] = await Promise.all([
        supabase.rpc("shipper_shipment_batch_candidates_v1"),
        supabase.rpc("shipper_package_receipt_dashboard_v1"),
      ]);

      if (cancelled) return;

      const candidates = (candidateData ?? []) as ShipmentCandidateRow[];
      const dashboardRows = (dashboardData ?? []) as ReceiptDashboardRow[];
      const reviewStateResults = await Promise.all(
        dashboardRows
          .filter((row) => Boolean(row.order_id && row.tracking_submission_id))
          .map(async (row) => {
            const { data } = await supabase.rpc("shipper_tracking_review_state_v1", {
              p_order_id: row.order_id,
              p_tracking_submission_id: row.tracking_submission_id,
            });
            return [row.tracking_submission_id, (data?.[0] ?? null) as TrackingReviewState | null] as const;
          })
      );
      if (cancelled) return;

      const reviewStateByTrackingId = new Map<string, TrackingReviewState>();
      reviewStateResults.forEach(([trackingId, reviewState]) => {
        if (trackingId && reviewState) reviewStateByTrackingId.set(trackingId, reviewState);
      });
      const candidateIds = new Set(
        candidates
          .map((row) => row.tracking_submission_id)
          .filter((value): value is string => Boolean(value))
      );
      const dashboardByTrackingId = new Map(
        dashboardRows
          .filter((row): row is ReceiptDashboardRow & { tracking_submission_id: string } => Boolean(row.tracking_submission_id))
          .map((row) => [row.tracking_submission_id, row])
      );

      const now = Date.now();
      document.querySelectorAll<HTMLTableRowElement>("table tbody tr").forEach((row) => {
        const trackingId = trackingIdFromRow(row);
        if (trackingId) replaceAction(row, trackingId, candidateIds, dashboardByTrackingId, reviewStateByTrackingId, now);
      });

      document.querySelectorAll<HTMLElement>("p").forEach((label) => {
        if (label.textContent?.trim() !== "Ready to ship") return;
        const count = label.parentElement?.querySelector<HTMLElement>("p.mt-1");
        if (count) count.textContent = String(candidateIds.size);
      });

      const nextDeadline = Array.from(reviewStateByTrackingId.values())
        .filter((reviewState) => reviewState.active_review_yn && reviewState.review_expires_at)
        .map((reviewState) => Date.parse(String(reviewState.review_expires_at)))
        .filter((deadline) => Number.isFinite(deadline) && deadline > now)
        .sort((a, b) => a - b)[0];

      if (nextDeadline && !refreshScheduled) {
        refreshScheduled = true;
        window.setTimeout(() => {
          if (!cancelled) router.refresh();
        }, Math.max(1000, nextDeadline - Date.now() + 1000));
      }
    }

    void loadAndApply();
    const intervalId = window.setInterval(() => void loadAndApply(), 60000);

    return () => {
      cancelled = true;
      window.clearInterval(intervalId);
    };
  }, [pathname, router]);

  return null;
}
