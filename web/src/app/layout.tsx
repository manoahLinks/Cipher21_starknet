import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Cipher21",
  description: "Confidential blackjack on Starknet, settled through the STRK20 privacy pool.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
