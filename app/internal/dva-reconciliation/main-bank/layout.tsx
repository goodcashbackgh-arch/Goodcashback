import type { ReactNode } from "react";
import ReleaseGuard from "./ReleaseGuard";

export default function MainBankMatchingLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <ReleaseGuard />
      {children}
    </>
  );
}
