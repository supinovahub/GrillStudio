import type { Metadata } from "next";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { getPreviewEnvironment } from "@/lib/environment";
import {
  mergeContactsAction,
  transitionOpportunityAction,
} from "@/lib/leads/actions";
import {
  getContactMergeCandidates,
  getLeadDetail,
} from "@/lib/leads/queries";
import {
  pipelineStageLabels,
} from "@/lib/leads/types";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Detalhe do Lead",
};

type PageProps = {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ resultado?: string }>;
};

const statusMessages: Record<string, string> = {
  "contatos-fundidos":
    "Contatos fundidos. Telefones, origens, Opt-out e histórico foram preservados.",
  "etapa-alterada": "Etapa atualizada com histórico e auditoria.",
  "fusao-bloqueada-conversas":
    "A fusão foi bloqueada porque os dois Contatos têm Conversas ativas.",
  "fusao-invalida": "Escolha outro Contato para concluir a fusão.",
  "fusao-negada": "A fusão foi recusada pelas regras de acesso ou integridade.",
  "lead-criado": "Lead cadastrado sem iniciar qualquer envio.",
  "motivo-obrigatorio": "Informe o motivo ao mover para Perdido.",
  "transicao-negada": "A regra do pipeline recusou essa alteração.",
  "versao-desatualizada":
    "O Lead foi alterado por outra pessoa. Revise os dados antes de tentar novamente.",
};

function formatDate(date: string): string {
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(date));
}

export default async function LeadDetailPage({
  params,
  searchParams,
}: PageProps) {
  const [{ id }, query, workspace, environment] = await Promise.all([
    params,
    searchParams,
    getMemberWorkspace(),
    Promise.resolve(getPreviewEnvironment()),
  ]);

  if (!workspace) {
    redirect("/aguardando-aprovacao");
  }

  const detail = await getLeadDetail(id);
  if (!detail) {
    notFound();
  }

  const canManage = workspace.member_roles.some((role) =>
    ["owner", "manager"].includes(role),
  );
  const mergeCandidates = canManage
    ? await getContactMergeCandidates(
        workspace.operation_id,
        detail.contact_id,
      )
    : [];
  const statusMessage = query.resultado
    ? statusMessages[query.resultado]
    : null;

  return (
    <AppShell
      activePath="/app/leads"
      environment={environment}
      workspace={workspace}
    >
      <main className="central lead-detail-page" id="conteudo">
        {statusMessage ? (
          <p className="persistent-notice" role="status">
            {statusMessage}
          </p>
        ) : null}

        <section className="central-heading">
          <div>
            <p className="eyebrow">Oportunidade</p>
            <h1>{detail.display_name || "Nome não informado"}</h1>
            <p>
              <Link className="text-link" href="/app/leads">
                Voltar para Leads
              </Link>
              {" · "}
              {detail.phones[0]?.e164 || "Telefone não informado"}
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Etapa atual</span>
            <strong>{pipelineStageLabels[detail.stage]}</strong>
            <span>
              {detail.assigned_name || "Sem responsável"} · v{detail.version}
            </span>
            <small>
              {detail.has_opt_out ? "Opt-out ativo" : "Sem Opt-out ativo"}
            </small>
          </div>
        </section>

        <div className="lead-detail-grid">
          <section className="lead-panel" aria-labelledby="identity-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Pessoa</p>
                <h2 id="identity-title">Contato</h2>
              </div>
              <span className="neutral-badge">{detail.contact_status}</span>
            </div>
            <dl className="lead-detail-facts">
              <div>
                <dt>Nome de uso</dt>
                <dd>{detail.display_name || "Não informado"}</dd>
              </div>
              <div>
                <dt>Origem atual</dt>
                <dd>{detail.source_type}</dd>
              </div>
              <div>
                <dt>Unidades na decisão</dt>
                <dd>
                  {detail.unit_count} ·{" "}
                  {detail.amount_scope === "total"
                    ? "valores totais"
                    : "valores por unidade"}
                </dd>
              </div>
              <div>
                <dt>Criado</dt>
                <dd>{formatDate(detail.created_at)}</dd>
              </div>
            </dl>
            <h3>Telefones</h3>
            <ul className="lead-detail-list">
              {detail.phones.map((phone) => (
                <li key={phone.id}>
                  <strong>{phone.e164}</strong>
                  <span>
                    Original: {phone.original_value}
                    {phone.is_primary ? " · principal" : ""}
                  </span>
                  {phone.observations.length > 1 ? (
                    <small>
                      {phone.observations.length} valores originais preservados
                    </small>
                  ) : null}
                </li>
              ))}
            </ul>
          </section>

          <section className="lead-panel" aria-labelledby="context-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Fronteiras de contexto</p>
                <h2 id="context-title">Contexto e nota</h2>
              </div>
            </div>
            <div className="lead-context-block">
              <strong>Contexto para Pedro</strong>
              <p>{detail.pedro_context || "Nenhum contexto informado."}</p>
            </div>
            {canManage ? (
              <div className="lead-context-block internal">
                <strong>Nota interna</strong>
                <p>{detail.internal_note || "Nenhuma nota interna."}</p>
                <small>Este conteúdo não entra no payload de Pedro.</small>
              </div>
            ) : null}
            {detail.proactive_request ? (
              <div className="lead-context-block">
                <strong>Abordagem proativa solicitada</strong>
                <p>
                  Estado: {detail.proactive_request.status}. Solicitar não
                  enviou mensagem nem confirmou autorização.
                </p>
              </div>
            ) : null}
          </section>

          <section className="lead-panel" aria-labelledby="participants-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Mesma decisão de compra</p>
                <h2 id="participants-title">Participantes</h2>
              </div>
              <span className="count-badge">
                {detail.participants.length}
              </span>
            </div>
            {detail.participants.length > 0 ? (
              <ul className="lead-detail-list">
                {detail.participants.map((participant) => (
                  <li key={participant.id}>
                    <strong>{participant.display_name}</strong>
                    <span>
                      {participant.role} ·{" "}
                      {participant.phone_e164 || "Sem telefone"}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="empty-copy">
                Nenhum participante adicional nesta Oportunidade.
              </p>
            )}
          </section>

          <section className="lead-panel" aria-labelledby="sources-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Sem sobrescrever</p>
                <h2 id="sources-title">Origens</h2>
              </div>
              <span className="count-badge">{detail.sources.length}</span>
            </div>
            <ul className="lead-detail-list">
              {detail.sources.map((source) => (
                <li key={source.id}>
                  <strong>{source.source_label || source.source_type}</strong>
                  <span>{formatDate(source.attributed_at)}</span>
                </li>
              ))}
            </ul>
          </section>

          <section
            className="lead-panel lead-history-panel"
            aria-labelledby="history-title"
          >
            <div className="section-heading">
              <div>
                <p className="eyebrow">Append-only</p>
                <h2 id="history-title">Histórico da Etapa</h2>
              </div>
              <span className="count-badge">{detail.history.length}</span>
            </div>
            <ol className="lead-history">
              {detail.history.map((event) => (
                <li key={event.id}>
                  <span aria-hidden="true" />
                  <div>
                    <strong>
                      {event.from_stage
                        ? `${pipelineStageLabels[event.from_stage]} → `
                        : "Entrada em "}
                      {pipelineStageLabels[event.to_stage]}
                    </strong>
                    <p>
                      {event.reason || "Sem motivo adicional"} ·{" "}
                      {formatDate(event.created_at)}
                    </p>
                  </div>
                </li>
              ))}
            </ol>
          </section>

          <section className="lead-panel" aria-labelledby="transition-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Servidor autoritativo</p>
                <h2 id="transition-title">Alterar Etapa</h2>
              </div>
            </div>
            {detail.allowed_actions.length === 0 ? (
              <p className="empty-copy">
                Esta Etapa só pode mudar pelo fluxo protegido do domínio
                responsável.
              </p>
            ) : (
              <form
                action={transitionOpportunityAction}
                className="form-stack compact-form"
              >
                <input
                  name="opportunity_id"
                  type="hidden"
                  value={detail.id}
                />
                <input
                  name="expected_version"
                  type="hidden"
                  value={detail.version}
                />
                <input
                  name="return_to"
                  type="hidden"
                  value={`/app/leads/${detail.id}`}
                />
                <div className="field">
                  <label htmlFor="target-stage">Nova Etapa</label>
                  <select
                    defaultValue=""
                    id="target-stage"
                    name="target_stage"
                    required
                  >
                    <option disabled value="">
                      Selecione
                    </option>
                    {detail.allowed_actions.map((stage) => (
                        <option key={stage} value={stage}>
                          {pipelineStageLabels[stage]}
                        </option>
                      ))}
                  </select>
                </div>
                <div className="field">
                  <label htmlFor="transition-reason">
                    Motivo ou contexto
                  </label>
                  <textarea
                    id="transition-reason"
                    name="transition_reason"
                    placeholder="Obrigatório para Perdido"
                    rows={3}
                  />
                </div>
                {detail.stage === "lost" ? (
                  <label className="check-field">
                    <input name="human_decision" type="checkbox" />
                    <span>
                      Confirmo a decisão humana de reativar a Oportunidade
                    </span>
                  </label>
                ) : null}
                <button className="button button-primary" type="submit">
                  Confirmar alteração
                </button>
              </form>
            )}
          </section>

          {canManage ? (
            <section
              className="lead-panel lead-merge-panel"
              aria-labelledby="merge-title"
            >
              <div className="section-heading">
                <div>
                  <p className="eyebrow">Decisão manual</p>
                  <h2 id="merge-title">Fundir Contato duplicado</h2>
                </div>
              </div>
              <p className="empty-copy">
                A Oportunidade atual e este Contato serão preservados como
                principais. A fusão é bloqueada se ambos tiverem Conversa
                ativa.
              </p>
              {mergeCandidates.length > 0 ? (
                <form
                  action={mergeContactsAction}
                  className="form-stack compact-form"
                >
                  <input
                    name="primary_contact_id"
                    type="hidden"
                    value={detail.contact_id}
                  />
                  <input
                    name="expected_primary_version"
                    type="hidden"
                    value={detail.contact_version}
                  />
                  <input
                    name="operation_id"
                    type="hidden"
                    value={workspace.operation_id}
                  />
                  <input
                    name="opportunity_id"
                    type="hidden"
                    value={detail.id}
                  />
                  <div className="field">
                    <label htmlFor="duplicate-contact">
                      Contato a incorporar
                    </label>
                    <select
                      defaultValue=""
                      id="duplicate-contact"
                      name="duplicate_contact_ref"
                      required
                    >
                      <option disabled value="">
                        Selecione pelo nome e telefone
                      </option>
                      {mergeCandidates.map((candidate) => (
                        <option
                          key={candidate.id}
                          value={`${candidate.id}:${candidate.version}`}
                        >
                          {candidate.display_name || "Nome não informado"} ·{" "}
                          {candidate.phone_e164 || "sem telefone"}
                          {candidate.active_conversations > 0
                            ? " · Conversa ativa"
                            : ""}
                        </option>
                      ))}
                    </select>
                  </div>
                  <button className="button button-danger" type="submit">
                    Fundir e preservar histórico
                  </button>
                </form>
              ) : (
                <p className="empty-copy">
                  Nenhum outro Contato ativo disponível para comparação.
                </p>
              )}
            </section>
          ) : null}
        </div>
      </main>
    </AppShell>
  );
}
