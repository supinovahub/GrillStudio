import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { PipelineBoard } from "@/components/pipeline-board";
import { getPreviewEnvironment } from "@/lib/environment";
import { getPipelineBoard } from "@/lib/leads/queries";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Kanban",
};

type PageSearchParams = Promise<{ resultado?: string }>;

const statusMessages: Record<string, string> = {
  "call-sem-responsavel":
    "Call agendada exige uma Call aceita por Corretor ou atribuída por Gestor.",
  "etapa-alterada": "Etapa atualizada com histórico e auditoria.",
  "motivo-obrigatorio": "Informe o motivo para mover o Lead a Perdido.",
  "transicao-invalida": "A alteração solicitada é inválida.",
  "transicao-negada":
    "A regra do pipeline recusou essa transição.",
  "versao-desatualizada":
    "O Lead mudou desde que você abriu o Kanban. Revise o card e tente novamente.",
};

export default async function KanbanPage({
  searchParams,
}: {
  searchParams: PageSearchParams;
}) {
  const [workspace, environment, params] = await Promise.all([
    getMemberWorkspace(),
    Promise.resolve(getPreviewEnvironment()),
    searchParams,
  ]);

  if (!workspace) {
    redirect("/aguardando-aprovacao");
  }

  const board = await getPipelineBoard(workspace.operation_id);
  const statusMessage = params.resultado
    ? statusMessages[params.resultado]
    : null;

  return (
    <AppShell
      activePath="/app/kanban"
      environment={environment}
      workspace={workspace}
    >
      <main className="central kanban-page" id="conteudo">
        {statusMessage ? (
          <p className="persistent-notice" role="status">
            {statusMessage}
          </p>
        ) : null}
        <section className="central-heading">
          <div>
            <p className="eyebrow">Início ao desfecho</p>
            <h1>Kanban</h1>
            <p>
              Nove etapas fixas. Toda movimentação passa pela regra
              transacional do servidor e gera histórico.
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Estado canônico</span>
            <strong>{board.cards.length} cards visíveis</strong>
            <span>{workspace.operation_name}</span>
            <small>Postgres + RLS</small>
          </div>
        </section>
        <PipelineBoard board={board} returnTo="/app/kanban" />
      </main>
    </AppShell>
  );
}
