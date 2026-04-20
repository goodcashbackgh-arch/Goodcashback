import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export default async function ImporterPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirect("/auth/check");
  }

  return (
    <main className="min-h-screen p-6">
      <h1 className="text-2xl font-semibold">Goodcashback Importer</h1>
      <p>Operator / importer shell</p>
      <p>Welcome: {operator.full_name}</p>
    </main>
  );
}
