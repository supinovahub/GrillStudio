"use client";

export default function TeamError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="centered-state" id="conteudo">
      <section className="state-panel" aria-labelledby="team-error-title">
        <p className="eyebrow">Equipe indisponível</p>
        <h1 id="team-error-title">Não foi possível carregar os Membros</h1>
        <p>
          Nenhuma permissão foi alterada. Tente novamente quando a conexão com
          a Preview Branch estiver estável.
        </p>
        <button className="button button-primary" onClick={reset} type="button">
          Tentar novamente
        </button>
      </section>
    </main>
  );
}
