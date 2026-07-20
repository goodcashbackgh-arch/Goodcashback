import type { ReactNode } from "react";
import ShipperDashboardShipmentGate from "./ShipperDashboardShipmentGate";

export default function ShipperLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <ShipperDashboardShipmentGate />
      {children}
    </>
  );
}
