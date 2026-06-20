import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import OnboardingWorkspace from "./OnboardingWorkspace";

type SearchParams = { saved?: string | string[] | undefined };

function savedMessageFrom(params: SearchParams | undefined) {
  const value = params?.saved;
  return Array.isArray(value) ? value[0] : value;
}

export default async function InternalOnboardingPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("internal_onboarding_overview_v1");
  if (error) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-8 text-slate-950">
        <section className="mx-auto max-w-3xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-bold uppercase tracking-[0.2em] text-rose-600">Onboarding RPC not ready</p>
          <h1 className="mt-2 text-2xl font-semibold">Run onboarding migrations first</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">{error.message}</p>
        </section>
      </main>
    );
  }

  const overview = (data ?? {}) as any;

  return (
    <OnboardingWorkspace
      staff={{ full_name: staff.full_name, role_type: staff.role_type }}
      countries={overview.countries ?? []}
      shippers={overview.shippers ?? []}
      importers={overview.importers ?? []}
      operators={overview.operators ?? []}
      exportProfiles={overview.export_profiles ?? []}
      supervisors={overview.supervisors ?? []}
      blockers={overview.blockers ?? {}}
      savedMessage={savedMessageFrom(params)}
    />
  );
}
