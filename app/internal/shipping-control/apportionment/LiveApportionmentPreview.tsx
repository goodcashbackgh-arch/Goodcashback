"use client";

import { useMemo, useState } from "react";

type PreviewRow = {
  tracking_submission_id: string | null;
  order_id: string | null;
  order_ref: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  adjusted_net_value_gbp: number | string | null;
  suggested_category_code: string | null;
  blocker: string | null;
};

type RuleRow = {
  rule_code: string;
  label: string;
  default_factor: number | string;
  active: boolean;
};

type Props = {
  rows: PreviewRow[];
  rules: RuleRow[];
  canApprove: boolean;
  sourceCurrency: string;
  sourceTotal: number;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function round(value: number, places: number) {
  const factor = 10 ** places;
  return Math.round((value + Number.EPSILON) * factor) / factor;
}

function money(value: number, currency: string) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency || "GBP" }).