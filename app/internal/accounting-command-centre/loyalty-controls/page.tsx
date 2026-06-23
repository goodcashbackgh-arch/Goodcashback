import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import CompletionLoyaltyAppliedAccountingPreviewPanel from "../CompletionLoyaltyAppliedAccountingPreviewPanel";
import LoyaltyAccountingControlPanel from "../LoyaltyAccountingControlPanel";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

export default async function LoyaltyAccountingControlsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
              <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Read-only control lane</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Completion loyalty accounting controls</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                This page exposes completion-loyalty accounting-control rows without making them selectable for freeze, batch creation, Sage posting, or cash-lane posting. It is evidence and review only.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name) || "Staff"}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
        </section>

        <LoyaltyAccountingControlPanel />

        <CompletionLoyaltyAppliedAccountingPreviewPanel />

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-bold">Control boundary</h2>
          <p className="mt-2">
            Pending loyalty, staged main-bank OUT, and released unused loyalty must not create VAT timing or Sage posting. Only staff-applied loyalty creates the existing <code>credit_applied</code> order-funding event, which the VAT timing engine already understands.
          </p>
        </section>
      </div>
    </main>
  );
}
