"use client";

export default function CentralError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="centered-state" id="conteudo">
      <div className="state-panel" role="alert">
        <p className="eyebrow">Erro recuperável</p>
        <h1>Não foi possível carregar a Central</h1>
        <p>
          Sua sessão continua protegida. Tente novamente sem trocar de
          ambiente.
        </p>
        <button className="button button-primary" onClick={reset} type="button">
          Tentar novamente
        </button>
      </div>
    </main>
  );
}
