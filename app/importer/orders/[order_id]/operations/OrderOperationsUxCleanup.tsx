"use client";

import { useEffect } from "react";

type InvoiceTotalPresentation = {
  invoiceRef: string;
  goodsQty: number;
  lineTotalGbp: number;
  enteredTotalGbp: number | null;
  ocrTotalGbp: number | null;
  deliveryAdjustmentGbp: number;
  discountAdjustmentGbp: number;
};

type BundleSummary = {