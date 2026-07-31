import type { Metadata } from "next";
import { randomUUID } from "node:crypto";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { getPreviewEnvironment } from "@/lib/environment";
import {
  assumeConversationAction,
  pauseConversationAction,
  returnConversationAction,
  sendHumanMessageAction,
} from "@/lib/inbox/actions";
import { getConversationDetail } from "@/lib/inbox/queries";
import { pipelineStageLabels } from "@/lib/leads/types";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = { title: "Conversa" };

type PageProps = {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ resultado?: string }>;
};

const statusMessages: Record<string, string> = {
  assumido: "Você assumiu esta Conversa.",
  pausado: "Conversa pausada sob seu Ownership.",
  devolvido: "Conversa devolvida para Pedro.",
  "devolucao-pendente":
    "Sem capacidade agora. A devolução ficou pendente e você continua responsável.",
  "mensagem-enviada":
    "Resposta capturada pelo simulador. Nenhum destinatário real foi usado.",
  "mensagem-negada": "A resposta foi recusada. Revise o Ownership e a versão.",
  "comando-negado": "O comando foi recusado pelas regras de Ownership.",
  "versao-desatualizada":
    "A Conversa mudou. Revise o estado atual antes de tentar novamente.",
  "motivo-obrigatorio": "Informe o motivo da pausa.",
};

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(value));
}

export default async function ConversationPage({
  params,
  searchParams,
}: PageProps) {
  const [{ id }, query, workspace, environment] = await Promise.all([
    params,
    searchParams,
    getMemberWorkspace(),
    Promise.resolve(getPreviewEnvironment()),
  ]);
  if (!workspace) redirect("/aguardando-aprovacao");
  if (
    !workspace.member_roles.includes("owner") &&
    !workspace.member_permissions.includes("manage_conversations")
  ) {
    redirect("/sem-permissao");
  }

  const conversation = await getConversationDetail(id);
  if (!conversation) notFound();
  const returnTo = `/app/atendimentos/${conversation.id}`;
  const statusMessage = query.resultado
    ? statusMessages[query.resultado]
    : null;

  return (
    <AppShell
      activePath="/app/atendimentos"
      environment={environment}
      workspace={workspace}
    >
      <main className="central conversation-page" id="conteudo">
        {statusMessage ? (
          <p className="persistent-notice" role="status">
            {statusMessage}
          </p>
        ) : null}

        <section className="conversation-heading">
          <div>
            <Link className="text-link" href="/app/atendimentos">
              ← Voltar para Atendimentos
            </Link>
            <h1>{conversation.contact.display_name || "Nome não informado"}</h1>
            <p>
              {pipelineStageLabels[conversation.opportunity.stage]} ·{" "}
              {conversation.connection?.name || "Sem conexão"}
            </p>
          </div>
          <div className="inbox-badges">
            <span>
              {conversation.ownership_type === "pedro"
                ? "Ownership: Pedro"
                : `Ownership: ${conversation.assigned_name || "Humano"}`}
            </span>
            <span>Modo: {conversation.automation_mode}</span>
            {conversation.is_paused ? <span>Pausada</span> : null}
            {conversation.pending_return ? (
              <span>Devolução pendente</span>
            ) : null}
          </div>
        </section>

        <div className="conversation-layout">
          <section className="conversation-thread" aria-label="Mensagens">
            {conversation.messages.map((message) => (
              <article
                className={`message-bubble ${message.direction}`}
                key={message.id}
              >
                <span>
                  {message.direction === "inbound" ? "Lead" : "Você"}
                </span>
                <p>
                  {message.body ||
                    `Conteúdo ${message.kind} sem prévia de texto.`}
                </p>
                <time>{formatDate(message.occurred_at)}</time>
              </article>
            ))}
            {!conversation.messages.length ? (
              <p className="empty-copy">Nenhuma mensagem nesta Conversa.</p>
            ) : null}

            {conversation.is_owned_by_actor && !conversation.is_paused ? (
              <form action={sendHumanMessageAction} className="message-composer">
                <input name="command_id" type="hidden" value={randomUUID()} />
                <input
                  name="conversation_id"
                  type="hidden"
                  value={conversation.id}
                />
                <input
                  name="expected_version"
                  type="hidden"
                  value={conversation.version}
                />
                <input name="return_to" type="hidden" value={returnTo} />
                <label htmlFor="message-text">Responder como humano</label>
                <textarea
                  id="message-text"
                  name="message_text"
                  placeholder="Esta resposta será capturada apenas pelo simulador."
                  required
                  rows={3}
                />
                <button className="button button-primary" type="submit">
                  Capturar resposta
                </button>
              </form>
            ) : null}
          </section>

          <aside className="conversation-context">
            <section className="lead-panel">
              <p className="eyebrow">Contexto</p>
              <h2>Oportunidade</h2>
              <dl className="lead-detail-facts">
                <div>
                  <dt>Etapa</dt>
                  <dd>{pipelineStageLabels[conversation.opportunity.stage]}</dd>
                </div>
                <div>
                  <dt>Origem comercial</dt>
                  <dd>{conversation.opportunity.source_type}</dd>
                </div>
                <div>
                  <dt>Conexão fixa</dt>
                  <dd>{conversation.connection?.name || "Não fixada"}</dd>
                </div>
                <div>
                  <dt>Canal</dt>
                  <dd>
                    {conversation.connection?.adapter_type || "Manual"}
                    {conversation.connection?.is_test ? " · teste" : ""}
                  </dd>
                </div>
                <div>
                  <dt>Versão</dt>
                  <dd>v{conversation.version}</dd>
                </div>
              </dl>
              <div className="lead-context-block">
                <strong>Contexto para Pedro</strong>
                <p>
                  {conversation.opportunity.pedro_context ||
                    "Nenhum contexto registrado."}
                </p>
              </div>
            </section>

            <section className="lead-panel ownership-panel">
              <p className="eyebrow">Escritor único</p>
              <h2>Ownership</h2>
              {conversation.requires_human_review ? (
                <p className="ownership-warning">
                  Revisão humana necessária: {conversation.review_reason}.
                </p>
              ) : null}
              {conversation.ownership_type === "pedro" ? (
                <form action={assumeConversationAction}>
                  <input
                    name="conversation_id"
                    type="hidden"
                    value={conversation.id}
                  />
                  <input
                    name="expected_version"
                    type="hidden"
                    value={conversation.version}
                  />
                  <input name="return_to" type="hidden" value={returnTo} />
                  <button className="button button-primary" type="submit">
                    Assumir atendimento
                  </button>
                </form>
              ) : null}

              {(conversation.ownership_type === "pedro" ||
                conversation.is_owned_by_actor) &&
              !conversation.is_paused ? (
                <form action={pauseConversationAction} className="form-stack">
                  <input
                    name="conversation_id"
                    type="hidden"
                    value={conversation.id}
                  />
                  <input
                    name="expected_version"
                    type="hidden"
                    value={conversation.version}
                  />
                  <input name="return_to" type="hidden" value={returnTo} />
                  <label htmlFor="pause-reason">Motivo da pausa</label>
                  <input
                    id="pause-reason"
                    name="pause_reason"
                    placeholder="Ex.: gestor revisando o caso"
                    required
                  />
                  <button className="button" type="submit">
                    Pausar e assumir
                  </button>
                </form>
              ) : null}

              {conversation.is_owned_by_actor ? (
                <form action={returnConversationAction} className="form-stack">
                  <input
                    name="conversation_id"
                    type="hidden"
                    value={conversation.id}
                  />
                  <input
                    name="expected_version"
                    type="hidden"
                    value={conversation.version}
                  />
                  <input name="return_to" type="hidden" value={returnTo} />
                  <label htmlFor="automation-mode">Modo ao devolver</label>
                  <select
                    defaultValue={
                      conversation.allowed_return_modes.includes(
                        conversation.automation_mode,
                      )
                        ? conversation.automation_mode
                        : "shadow"
                    }
                    id="automation-mode"
                    name="automation_mode"
                  >
                    {conversation.allowed_return_modes.map((mode) => (
                      <option key={mode} value={mode}>
                        {mode === "shadow"
                          ? "Sombra"
                          : mode === "assisted"
                            ? "Assistido"
                            : "Produção"}
                      </option>
                    ))}
                  </select>
                  <button className="button" type="submit">
                    Devolver para Pedro
                  </button>
                </form>
              ) : null}
            </section>
          </aside>
        </div>
      </main>
    </AppShell>
  );
}
