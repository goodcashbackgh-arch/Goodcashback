import { redirect } from "next/navigation";

export default function LegacySageVatReconstructionPage() {
  redirect("/internal/accounting-vat?tab=sage");
}
