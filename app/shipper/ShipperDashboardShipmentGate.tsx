"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

type ShipmentCandidateRow = {
  tracking_submission_id: string | null;
};

type ReceiptDashboardRow = {
  tracking_submission_id: string | null;
  latest_receipt_status: string | null;
  latest_receipt_recorded_at: string | null;
  in_active_shipment