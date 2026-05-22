import { NextResponse } from "next/server";
import { freezeMatchingSupplierCreditNoteRowsAction } from "../supplierCreditActions";

export async function POST(request: Request) {
  const formData = await request.formData();
  await freezeMatchingSupplierCreditNoteRowsAction(formData);
  return NextResponse.redirect(new URL("/internal/accounting-command-centre?lane=supplier_credit_note", request.url));
}
