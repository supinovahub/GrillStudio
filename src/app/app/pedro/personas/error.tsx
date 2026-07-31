"use client";

export default function PersonaContextError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="page-content context-page">
      <div className="error-card" role="alert">
        <p className="eyebrow">Contexto indisponível</p>
        <h1>Não foi possível carregar as versões</h1>
        <p>
          Nenhuma publicação foi alterada. Tente reconciliar a tela com o
          estado canônico.
        </p>
        <button className="secondary-button" onClick={reset} type="button">
          Tentar novamente
        </button>
      </div>
    </main>
  );
}
