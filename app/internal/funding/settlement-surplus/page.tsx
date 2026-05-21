import { redirect } from "next/navigation";

export default function SettlementSurplusRedirectPage() {
  redirect("/internal/funding/surplus-evidence");
}
