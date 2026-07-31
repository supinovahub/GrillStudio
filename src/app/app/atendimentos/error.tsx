"use client";

export default function InboxError({
  reset,
}: {
  reset: () => void;
}) {
  return (
    <main className="central">
      <p className="eyebrow">Inbox indisponível</p>
      <h1>Não foi possível carregar os Atendimentos.</h1>
      <button className="button button-primary" onClick={reset} type="button">
        Tentar novamente
      </button>
    </main>
  );
}
