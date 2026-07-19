"use client";

import { useEffect } from "react";

export default function SelectedInvoiceCookie({
  orderId,
  supplierInvoiceId,
}: {
  orderId: string;
  supplierInvoiceId: string | null;
}) {
  useEffect(() => {
    if (!supplierInvoiceId) return;
    document.cookie = `recon_invoice_${encodeURIComponent(orderId)}=${encodeURIComponent(supplierInvoiceId)}; Path=/importer/reconciliation/${encodeURIComponent(orderId)}; SameSite=Lax`;
  }, [orderId, supplierInvoiceId]);

  return null;
}
