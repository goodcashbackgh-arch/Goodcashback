"use client";

import { useEffect, useMemo, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

type CandidateRow = {
  supplier_invoice_id?: string | null;
  invoice_total_gbp?: number | string | null;
  confirmed_matched_gbp?: number