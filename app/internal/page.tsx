import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export default async function InternalPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) {
    redirect("/auth/check");
  }

  return (
    <main className="min-h-screen p-6">
      <h1 className="text-2xl font-semibold">Goodcashback Internal</h1>
      <p>Internal admin shell</p>
      <p>Welcome: {staff.full_name}</p>
    </main>
  );
}
