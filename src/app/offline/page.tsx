import type { Metadata } from "next";

import { BrandMark } from "@/components/brand-mark";

export const metadata: Metadata = {
  title: "Sem conexão",
};

export default function OfflinePage() {
  return (
    <main className="centered-state" id="conteudo">
      <div className="state-panel">
        <BrandMark />
        <p className="eyebrow">Sem conexão</p>
        <h1>A Operação não está disponível offline</h1>
        <p>
          Reconecte-se para consultar o estado canônico antes de tomar qualquer
          decisão.
        </p>
      </div>
    </main>
  );
}
