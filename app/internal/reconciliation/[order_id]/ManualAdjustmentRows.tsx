"use client";

import { useMemo, useState } from "react";
import {
  addSupplierAccountingAdjustmentLineAction,
  deleteSupplierAccountingAdjustmentLineAction,
} from "./actions";

type AdjustmentLine = {
  id: string;
  description: string;
  qty?: number | null;
  sku: string | null;
  size: string | null;
  sage_ledger_account_id: string | null;
  nominal_code: string | null;
  tax_rate_id: string | null;
  tax_rate_label: string | null;
  vat_rate_percent: number | null;
  net_amount_gbp: number | null;
  vat_amount_gbp: number | null;
  gross_amount_gbp: number | null;
};

type DraftRow = { id: string };

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function qtyDisplay(value: unknown) {
  const n = Number(value ?? 1);
  if (!Number.isFinite(n) || n <= 0) return "1";
  return Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

export default function ManualAdjustmentRows({
  orderId,
  invoiceId,
  adjustments,
}: {
  orderId: string;
  invoiceId: string;
  adjustments: AdjustmentLine[];
}) {
  const initialId = useMemo(() => `manual-${Date.now()}-0`, []);
  const [draftRows, setDraftRows] = useState<DraftRow[]>([{ id: initialId }]);

  function addDraftRow() {
    setDraftRows((rows) => [...rows, { id: `manual-${Date.now()}-${rows.length}` }]);
  }

  function deleteDraftRow(id: string) {
    setDraftRows((rows) => rows.filter((row) => row.id !== id));
  }

  return (
    <>
      {adjustments.map((line) => (
        <tr key={line.id} className="border-b bg-amber-50 align-top">
          <td className="p-2">Adj</td>
          <td className="p-2">{line.description}</td>
          <td className="p-2">{line.sku ?? "—"}</td>
          <td className="p-2">{line.size ?? "—"}</td>
          <td className="p-2">{qtyDisplay(line.qty)}</td>
          <td className="p-2">{line.nominal_code ?? "—"}</td>
          <td className="p-2">{line.sage_ledger_account_id ?? "—"}</td>
          <td className="p-2">{line.tax_rate_label ?? `${line.vat_rate_percent ?? 0}%`}</td>
          <td className="p-2">{gbp(line.net_amount_gbp)}</td>
          <td className="p-2">{gbp(line.vat_amount_gbp)}</td>
          <td className="p-2 font-semibold">{gbp(line.gross_amount_gbp)}</td>
          <td className="p-2">manual adjustment</td>
          <td className="p-2">
            <form action={deleteSupplierAccountingAdjustmentLineAction}>
              <input type="hidden" name="order_id" value={orderId} />
              <input type="hidden" name="adjustment_line_id" value={line.id} />
              <button className="rounded-lg border border-rose-300 bg-rose-50 px-3 py-1 font-semibold text-rose-800">Delete</button>
            </form>
          </td>
        </tr>
      ))}

      {draftRows.map((row) => {
        const formId = `add-adjustment-${row.id}`;
        return (
          <tr key={row.id} className="border-t bg-slate-50 align-top">
            <td className="p-2 font-semibold">New</td>
            <td className="p-2"><input form={formId} name="description" className="w-72 rounded-lg border px-2 py-1" placeholder="Manual line description" /></td>
            <td className="p-2"><input form={formId} name="sku" className="w-28 rounded-lg border px-2 py-1" /></td>
            <td className="p-2"><input form={formId} name="size" className="w-20 rounded-lg border px-2 py-1" /></td>
            <td className="p-2"><input form={formId} name="qty" type="number" min="0.001" step="0.001" defaultValue="1" className="w-20 rounded-lg border px-2 py-1" /></td>
            <td className="p-2"><input form={formId} name="nominal_code" className="w-24 rounded-lg border px-2 py-1" /></td>
            <td className="p-2"><input form={formId} name="sage_ledger_account_id" className="w-36 rounded-lg border px-2 py-1" /></td>
            <td className="p-2">
              <select form={formId} name="vat_rate_percent" defaultValue="20" className="w-32 rounded-lg border px-2 py-1">
                <option value="20">20% std</option>
                <option value="5">5% reduced</option>
                <option value="0">0%</option>
              </select>
              <input form={formId} type="hidden" name="tax_rate_label" value="manual" />
              <input form={formId} type="hidden" name="tax_rate_id" value="manual" />
            </td>
            <td className="p-2"><input form={formId} name="net_amount_gbp" type="number" step="0.01" className="w-24 rounded-lg border px-2 py-1" /></td>
            <td className="p-2"><input form={formId} name="vat_amount_gbp" type="number" step="0.01" className="w-24 rounded-lg border px-2 py-1" /></td>
            <td className="p-2 text-slate-500">net+VAT</td>
            <td className="p-2">unsaved</td>
            <td className="p-2">
              <div className="flex gap-2">
                <form id={formId} action={addSupplierAccountingAdjustmentLineAction}>
                  <input type="hidden" name="order_id" value={orderId} />
                  <input type="hidden" name="supplier_invoice_id" value={invoiceId} />
                  <button className="rounded-lg bg-slate-900 px-3 py-1 font-semibold text-white">Save</button>
                </form>
                <button type="button" onClick={() => deleteDraftRow(row.id)} className="rounded-lg border border-slate-300 bg-white px-3 py-1 font-semibold text-slate-700">Delete</button>
              </div>
            </td>
          </tr>
        );
      })}

      <tr className="bg-white">
        <td colSpan={13} className="p-2">
          <button type="button" onClick={addDraftRow} className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-semibold text-slate-800 hover:bg-slate-50">
            + Add manual row
          </button>
        </td>
      </tr>
    </>
  );
}
