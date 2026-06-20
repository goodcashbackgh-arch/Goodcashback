"use client";

import { useEffect, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";

export default function Notice({ message }: { message?: string | null }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [visible, setVisible] = useState(Boolean(message));

  useEffect(() => {
    if (!message) return;

    const nextParams = new URLSearchParams(searchParams.toString());
    nextParams.delete("saved");
    const nextQuery = nextParams.toString();
    router.replace(nextQuery ? `${pathname}?${nextQuery}` : pathname, { scroll: false });

    const timer = window.setTimeout(() => setVisible(false), 5000);
    return () => window.clearTimeout(timer);
  }, [message, pathname, router, searchParams]);

  if (!message || !visible) return null;

  return (
    <div className="mt-4 rounded-xl border border-green-300 bg-green-50 p-3 text-sm font-semibold text-green-900" role="status">
      {message}
    </div>
  );
}
