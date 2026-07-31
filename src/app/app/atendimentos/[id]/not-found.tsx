import Link from "next/link";

export default function ConversationNotFound() {
  return (
    <main className="central">
      <p className="eyebrow">Conversa não encontrada</p>
      <h1>Este Atendimento não está disponível.</h1>
      <Link className="button button-primary" href="/app/atendimentos">
        Voltar para Atendimentos
      </Link>
    </main>
  );
}

