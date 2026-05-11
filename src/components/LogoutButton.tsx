"use client";

import { usePathname } from "next/navigation";

export default function LogoutButton() {
  const pathname = usePathname();

  if (pathname === "/login") return null;

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
