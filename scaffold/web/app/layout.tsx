import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "HEX_PAYLOAD Genesis",
  description:
    "Fully on-chain generative art on Ritual Chain — prompts minted through the image precompile, provenance = tx hash.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
