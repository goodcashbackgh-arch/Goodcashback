"use client";

import { useSearchParams } from "next/navigation";
import Notice from "./notice";

export default function Template({ children }: { children: React.ReactNode }) {
  const params = useSearchParams();
  const message = params.get("saved");

  return (
    <>
      <div className="mx-auto max-w-7xl px-4 pt-4 sm:px-6">
        <Notice message={message} />
      </div>
      {children}
    </>
  );
}
