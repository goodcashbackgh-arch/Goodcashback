import type { Metadata } from "next";
import LogoutButton from "@/components/LogoutButton";
import StatusTextPatch from "./_components/StatusTextPatch";
import "./globals.css";

export const metadata: Metadata = {
  title: "Goodcashback",
  description: "Goodcashback app",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>
        <LogoutButton />
        <StatusTextPatch />
        {children}
      </body>
    </html>
  );
}