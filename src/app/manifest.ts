import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    background_color: "#f6f1e8",
    description: "Operação comercial imobiliária do primeiro contato à venda.",
    display: "standalone",
    icons: [
      {
        purpose: "any",
        sizes: "any",
        src: "/icon.svg",
        type: "image/svg+xml",
      },
      {
        purpose: "maskable",
        sizes: "any",
        src: "/icon.svg",
        type: "image/svg+xml",
      },
    ],
    id: "/",
    lang: "pt-BR",
    name: "GrillStudio",
    orientation: "any",
    scope: "/",
    short_name: "GrillStudio",
    start_url: "/app/central",
    theme_color: "#f6f1e8",
  };
}
