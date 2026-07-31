import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { getPreviewEnvironment } from "@/lib/environment";
import { getInboxList } from "@/lib/inbox/queries";
import { pipelineStageLabels } from "@/lib/leads/types";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = { title: "Atendimentos" };

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

const modeLabels = {
  assisted: "Assistido",
  production: "Produção",
  shadow: "Sombra",
} as const;

export default async function InboxPage() {
  const [workspace, environment] = await Promise.all([
    getMemberWorkspace(),
    Promise.resolve(getPreviewEnvironment()),
  ]);
  if (!workspace) redirect("/aguardando-aprovacao");
  if (!workspace.member_permissions.includes("manage_conversations")) {
    redirect("/sem-permissao");
  }

  const conversations = await getInboxList(workspace.operation_id);

  return (
    <AppShell
      activePath="/app/atendimentos"
      environment={environment}
      workspace={workspace}
    >
      <main className="central inbox-page" id="conteudo">
        <section className="central-heading">
          <div>
            <p className="eyebrow">Inbox operacional</p>
            <h1>Atendimentos</h1>
            <p>
              Cada Conversa tem uma origem fixa e exatamente um escritor.
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Conversas abertas</span>
            <strong>{conversations.length}</strong>
            <span>{workspace.operation_name}</span>
            <small>Atualização canônica no banco</small>
          </div>
        </section>

        {conversations.length ? (
          <section className="inbox-list" aria-label="Conversas abertas">
            {conversations.map((conversation) => (
              <Link
                className="inbox-list-item"
                href={`/app/atendimentos/${conversation.id}`}
                key={conversation.id}
              >
                <div className="inbox-list-heading">
                  <div>
                    <strong>
                      {conversation.display_name || "Nome não informado"}
                    </strong>
                    <span>
                      {conversation.connection_name || "Origem ainda não fixada"}
                    </span>
                  </div>
                  <time>{formatDate(conversation.last_message_at)}</time>
                </div>
                <p>
                  {conversation.last_message ||
                    `Mensagem ${conversation.last_message_kind || "recebida"}`}
                </p>
                <div className="inbox-badges">
                  <span>{pipelineStageLabels[conversation.stage]}</span>
                  <span>
                    {conversation.ownership_type === "pedro"
                      ? "Pedro"
                      : conversation.assigned_name || "Humano"}
                  </span>
                  <span>{modeLabels[conversation.automation_mode]}</span>
                  {conversation.is_paused ? <span>Pausada</span> : null}
                  {conversation.pending_return ? (
                    <span>Devolução pendente</span>
                  ) : null}
                  {conversation.requires_human_review ? (
                    <span>Revisão necessária</span>
                  ) : null}
                </div>
              </Link>
            ))}
          </section>
        ) : (
          <section className="lead-panel inbox-empty">
            <p className="eyebrow">Sem conversas</p>
            <h2>A Inbox está vazia</h2>
            <p>
              Um inbound sintético válido aparecerá aqui sem disparar nenhuma
              mensagem para um número real.
            </p>
          </section>
        )}
      </main>
    </AppShell>
  );
}
