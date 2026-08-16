import Link from "next/link";
import { redirect } from "next/navigation";
import {
  resolveCurrentPlatformAccess,
  workspacePath,
} from "@/utils/platform-access/server";

export default async function WorkspaceSelectPage() {
  let access;

  try {
    access = await resolveCurrentPlatformAccess();
  } catch {
    redirect("/auth/check");
  }

  if (!access.authenticated) {
    redirect("/login");
  }

  if (access.must_change_password === true) {
    redirect("/auth/change-password");
  }

  if (!(access.has_customer_membership && access.has_importer_membership)) {
    const path = workspacePath(access.resolved_workspace);
    if (path && path !== "/workspace/select") {
      redirect(path);
    }
    redirect("/auth/check");
  }

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-8 text-slate-950 sm:px-6">
      <section className="mx-auto max-w-4xl rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8">
        <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">Goods To Ship</p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">Choose your workspace</h1>
        <p className="mt-2 text-sm leading-6 text-slate-600">
          Your login has both Customer and Importer access. Choose the workspace you want to open.
        </p>

        <div className="mt-7 grid gap-4 md:grid-cols-2">
          <Link
            href="/customer"
            className="rounded-3xl border border-sky-200 bg-sky-50 p-6 transition hover:border-sky-300 hover:bg-sky-100"
          >
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-sky-700">Customer</p>
            <h2 className="mt-2 text-2xl font-semibold">Customer portal</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Orders, funding, account credit and customer-facing activity.</p>
            <p className="mt-5 text-sm font-bold text-sky-700">Open customer portal →</p>
          </Link>

          <Link
            href="/importer"
            className="rounded-3xl border border-slate-300 bg-white p-6 transition hover:border-slate-400 hover:bg-slate-50"
          >
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-600">Importer</p>
            <h2 className="mt-2 text-2xl font-semibold">Importer workspace</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Operational review, evidence, tracking, reconciliation and exceptions.</p>
            <p className="mt-5 text-sm font-bold text-slate-800">Open importer workspace →</p>
          </Link>
        </div>
      </section>
    </main>
  );
}
