"use client";

import { useEffect, useMemo, useState } from "react";
import { usePathname } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

export default function LogoutButton() {
  const pathname = usePathname();
  const supabase = useMemo(() => createClient(), []);
  const [isLoggedIn, setIsLoggedIn] = useState(false);

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

  if (!isLoggedIn || pathname === "/login") return null;

  return (
    <form action="/logout" method="post" className="fixed right-4 top-4 z-50">
      <button
        type="submit"
        className="rounded-xl border border-slate-300 bg-white/95 px-4 py-2 text-sm font-semibold text-slate-800 shadow-sm backdrop-blur hover:bg-slate-50"
      >
        Logout
      </button>
    </form>
  );
}
