"use client";

import { useEffect, useMemo, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

export default function LogoutButton() {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [isLoggingOut, setIsLoggingOut] = useState(false);

  useEffect(() => {
    let mounted = true;

    supabase.auth.getUser().then(({ data }) => {
      if (mounted) setIsLoggedIn(Boolean(data.user));
    });

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      setIsLoggedIn(Boolean(session?.user));
    });

    return () => {
      mounted = false;
      subscription.unsubscribe();
    };
  }, [supabase]);

  async function handleLogout() {
    setIsLoggingOut(true);
    await supabase.auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  if (!isLoggedIn || pathname === "/login") return null;

  return (
    <button
      type="button"
      onClick={handleLogout}
      disabled={isLoggingOut}
      className="fixed right-4 top-4 z-50 rounded-xl border border-slate-300 bg-white/95 px-4 py-2 text-sm font-semibold text-slate-800 shadow-sm backdrop-blur hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60"
    >
      {isLoggingOut ? "Logging out…" : "Logout"}
    </button>
  );
}
