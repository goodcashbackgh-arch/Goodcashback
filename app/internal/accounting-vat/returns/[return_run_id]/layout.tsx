import type { ReactNode } from "react";
import { SageOnlyPurchaseApprovalButton } from "./SageOnlyPurchaseApprovalButton";

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

export default async function VatReturnRunLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ return_run_id?: string }> | { return_run_id?: string };
}) {
  const resolvedParams = await params;
  const runId = text(resolvedParams?.return_run_id);

  return (
    <>
      {children}
      {runId ? <SageOnlyPurchaseApprovalButton runId={runId} /> : null}
    </>
  );
}
