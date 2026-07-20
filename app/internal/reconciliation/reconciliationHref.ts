type ReconciliationResult = {
  success?: string;
  error?: string;
};

export function supplierInvoiceReconciliationHref(
  orderId: string,
  supplierInvoiceId: string,
  result: ReconciliationResult = {},
) {
  const query = new URLSearchParams({ supplier_invoice_id: supplierInvoiceId });
  if (result.success) query.set("success", result.success);
  if (result.error) query.set("error", result.error);
  return `/internal/reconciliation/${orderId}?${query.toString()}`;
}
