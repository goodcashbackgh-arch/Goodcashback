import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import CashAllocationPanel from "../CashAllocationPanel";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function hasAccountingAccess(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

export default async function UnifiedCashAllocationPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  const canAccess = text(staff.role_type) === "admin" || hasAccountingAccess((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1600px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/accounting-command-centre/cash-posting" className="text-sm font-semibold text-sky-700">← Cash Posting Workbench</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Accounting cockpit · unified cash allocation</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">Unified Cash Allocation Workbench</h1>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            One allocation workbench for cash movements. Phase 1 proves customer/importer receipt-on-account allocation to the matched posted Sage sales invoice. Later supplier, shipper, refund and residual allocations should extend this same workbench instead of creating category-specific screens.
          </p>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-emerald-900">Customer receipt allocation wired</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Endpoint: POST /contact_allocations</span>
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">Auto-match: order ref · posted receipt · posted sales invoice · POA id</span>
          </div>
        </section>

        <CashAllocationPanel />
      </div>
    </main>
  );
}
