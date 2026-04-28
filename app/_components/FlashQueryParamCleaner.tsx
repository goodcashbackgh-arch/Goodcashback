"use client";

import { useEffect } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";

type FlashQueryParamCleanerProps = {
  keys?: string[];
};

export default function FlashQueryParamCleaner({
  keys = ["success", "error"],
}: FlashQueryParamCleanerProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (!pathname || !searchParams) return;

    const current = new URLSearchParams(searchParams.toString());
    let changed = false;

    for (const key of keys) {
      if (current.has(key)) {
        current.delete(key);
        changed = true;
      }
    }

    if (!changed) return;

    const nextQuery = current.toString();
    const nextUrl = nextQuery ? `${pathname}?${nextQuery}` : pathname;
    router.replace(nextUrl, { scroll: false });
  }, [keys, pathname, router, searchParams]);

  return null;
}
