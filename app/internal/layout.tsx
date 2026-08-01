import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export default async function InternalLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const { data: physicalData } = await (supabase as any).rpc("staff_physical_receipt_reviews_v1", { p_review_id: null });
  const physicalCount = Number(physicalData?.action_count ?? 0);

  return <>
    <div className="px-4 pt-4 md:px-6">
      <div className="mx-auto flex max-w-7xl justify-end">
        <Link href="/internal/physical-receipts" className="inline-flex items-center gap-2 rounded-full border border-violet-200 bg-violet-50 px-4 py-2 text-sm font-semibold text-violet-900 shadow-sm">
          Physical Receipt Reviews
          <span className="rounded-full bg-violet-900 px-2 py-0.5 text-xs text-white">{physicalCount}</span>
        </Link>
      </div>
    </div>
    {children}
  </>;
}
