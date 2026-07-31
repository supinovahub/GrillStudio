import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { PipelineBoard } from "@/components/pipeline-board";
import { getPreviewEnvironment } from "@/lib/environment";
import { getPipelineBoard } from "@/lib/leads/queries";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Meu pipeline",
};

export default async function MyPipelinePage() {
  const [workspace, environment] = await Promise.all([
    getMemberWorkspace(),
    Promise.resolve(getPreviewEnvironment()),
  ]);

  if (!workspace) {
    redirect("/aguardando-aprovacao");
  }

  const board = await getPipelineBoard(workspace.operation_id);

  return (
    <AppShell
      activePath="/app/meu-pipeline"
      environment={environment}
      workspace={workspace}
    >
      <main className="central kanban-page" id="conteudo">
        <section className="central-heading">
          <div>
            <p className="eyebrow">Escopo do Corretor</p>
            <h1>Meu pipeline</h1>
            <p>
              Somente Oportunidades atribuídas e liberadas a partir de Call
              agendada.
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Acesso mínimo</span>
            <strong>{board.cards.length} cards atribuídos</strong>
            <span>{workspace.operation_name}</span>
            <small>Isolamento aplicado no banco</small>
          </div>
        </section>
        <PipelineBoard board={board} returnTo="/app/meu-pipeline" />
      </main>
    </AppShell>
  );
}
