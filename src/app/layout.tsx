import type { Metadata, Viewport } from "next";

import { ServiceWorkerRegistration } from "@/components/service-worker-registration";

import "./globals.css";

export const metadata: Metadata = {
  applicationName: "GrillStudio",
  description: "Operação comercial imobiliária do primeiro contato à venda.",
  icons: {
    icon: "/icon.svg",
  },
  manifest: "/manifest.webmanifest",
  title: {
    default: "GrillStudio",
    template: "%s · GrillStudio",
  },
};

export const viewport: Viewport = {
  colorScheme: "light",
  themeColor: "#f6f1e8",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="pt-BR">
      <body>
        <a className="skip-link" href="#conteudo">
          Pular para o conteúdo
        </a>
        {children}
        <ServiceWorkerRegistration />
      </body>
    </html>
  );
}
