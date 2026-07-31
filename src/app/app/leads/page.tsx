import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { getPreviewEnvironment } from "@/lib/environment";
import { createManualLeadAction } from "@/lib/leads/actions";
import { getLeadList } from "@/lib/leads/queries";
import { pipelineStageLabels } from "@/lib/leads/types";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Leads",
};

type PageSearchParams = Promise<{ resultado?: string }>;

const statusMessages: Record<string, string> = {
  "cadastro-invalido":
    "Revise o WhatsApp, a origem e a decisão de cadastro.",
  "cadastro-negado": "Seu papel não permite cadastrar Leads.",
  "telefone-sem-ddd":
    "Informe o WhatsApp com DDD. O sistema não inventa essa informação.",
};

function formatDate(date: string): string {
  return new Intl.DateTimeFormat("pt-BR", {
    dateStyle: "short",
    timeStyle: "short",
  }).format(new Date(date));
}

export default async function LeadsPage({
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

  const canCreate = workspace.member_roles.some((role) =>
    ["owner", "manager"].includes(role),
  );
  if (!canCreate) {
    redirect("/sem-permissao");
  }
  const leads = await getLeadList(workspace.operation_id);
  const statusMessage = params.resultado
    ? statusMessages[params.resultado]
    : null;

  return (
    <AppShell
      activePath="/app/leads"
      environment={environment}
      workspace={workspace}
    >
      <main className="central lead-page" id="conteudo">
        {statusMessage ? (
          <p className="persistent-notice" role="status">
            {statusMessage}
          </p>
        ) : null}

        <section className="central-heading">
          <div>
            <p className="eyebrow">Contato · Oportunidade</p>
            <h1>Leads</h1>
            <p>
              A identidade da pessoa permanece separada da decisão de compra e
              do acompanhamento comercial.
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Pipeline fixo</span>
            <strong>{leads.length} oportunidades visíveis</strong>
            <span>{workspace.operation_name}</span>
            <small>RLS aplicado na lista e no detalhe</small>
          </div>
        </section>

        {canCreate ? (
          <section className="lead-panel" aria-labelledby="manual-lead-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Cadastro manual</p>
                <h2 id="manual-lead-title">Nova Oportunidade</h2>
              </div>
              <span className="neutral-badge">Sem envio automático</span>
            </div>
            <form
              action={createManualLeadAction}
              className="lead-form form-stack"
            >
              <input
                name="operation_id"
                type="hidden"
                value={workspace.operation_id}
              />
              <div className="lead-form-grid">
                <div className="field">
                  <label htmlFor="lead-name">Como podemos chamar</label>
                  <input
                    id="lead-name"
                    name="lead_name"
                    placeholder="Nome de uso, se conhecido"
                  />
                </div>
                <div className="field">
                  <label htmlFor="lead-phone">WhatsApp</label>
                  <input
                    id="lead-phone"
                    name="phone_original"
                    placeholder="(11) 99999-9999"
                    required
                    type="tel"
                  />
                  <small>
                    O valor digitado é preservado e a identidade usa E.164.
                  </small>
                </div>
                <div className="field">
                  <label htmlFor="lead-source">Origem</label>
                  <input
                    id="lead-source"
                    name="lead_source"
                    placeholder="Indicação, portal, evento..."
                    required
                  />
                </div>
                <div className="field">
                  <label htmlFor="lead-units">Quantidade de unidades</label>
                  <input
                    defaultValue="1"
                    id="lead-units"
                    max="100"
                    min="1"
                    name="unit_count"
                    required
                    type="number"
                  />
                </div>
                <div className="field">
                  <label htmlFor="lead-amount-scope">Valores informados</label>
                  <select
                    defaultValue="total"
                    id="lead-amount-scope"
                    name="amount_scope"
                  >
                    <option value="total">São totais</option>
                    <option value="per_unit">São por unidade</option>
                  </select>
                </div>
                <div className="field">
                  <label htmlFor="participant-name">
                    Participante adicional
                  </label>
                  <input
                    id="participant-name"
                    name="participant_name"
                    placeholder="Nome do co-comprador, se houver"
                  />
                </div>
                <div className="field">
                  <label htmlFor="participant-phone">
                    WhatsApp do participante
                  </label>
                  <input
                    id="participant-phone"
                    name="participant_phone"
                    placeholder="Opcional, mas sempre com DDD"
                    type="tel"
                  />
                </div>
              </div>

              <div className="lead-context-grid">
                <div className="field">
                  <label htmlFor="pedro-context">Contexto para Pedro</label>
                  <textarea
                    id="pedro-context"
                    name="pedro_context"
                    placeholder="Pode ser usado na conversa e no briefing."
                    rows={4}
                  />
                </div>
                <div className="field">
                  <label htmlFor="internal-note">Nota interna</label>
                  <textarea
                    id="internal-note"
                    name="internal_note"
                    placeholder="Nunca é incluída no contexto de Pedro."
                    rows={4}
                  />
                </div>
              </div>

              <fieldset className="choice-group lead-action-choice">
                <legend>O que fazer ao salvar</legend>
                <label className="check-field">
                  <input
                    defaultChecked
                    name="registration_action"
                    type="radio"
                    value="register"
                  />
                  <span>Apenas cadastrar</span>
                </label>
                <label className="check-field">
                  <input
                    name="registration_action"
                    type="radio"
                    value="assume"
                  />
                  <span>Assumir o atendimento</span>
                </label>
                <label className="check-field">
                  <input
                    name="registration_action"
                    type="radio"
                    value="request_proactive"
                  />
                  <span>
                    Solicitar futura Abordagem proativa — nenhum envio ocorre
                    agora
                  </span>
                </label>
              </fieldset>
              <button className="button button-primary" type="submit">
                Cadastrar Lead
              </button>
            </form>
          </section>
        ) : null}

        <section className="lead-panel" aria-labelledby="lead-list-title">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Visão autorizada</p>
              <h2 id="lead-list-title">Oportunidades</h2>
            </div>
            <span className="count-badge">{leads.length}</span>
          </div>
          {leads.length > 0 ? (
            <div className="lead-table-wrap">
              <table className="lead-table">
                <thead>
                  <tr>
                    <th>Lead</th>
                    <th>Etapa</th>
                    <th>Origem</th>
                    <th>Responsável</th>
                    <th>Atualizado</th>
                  </tr>
                </thead>
                <tbody>
                  {leads.map((lead) => (
                    <tr key={lead.id}>
                      <td>
                        <Link href={`/app/leads/${lead.id}`}>
                          {lead.display_name || "Nome não informado"}
                        </Link>
                        <span>{lead.phone_e164}</span>
                      </td>
                      <td>
                        <span className={`lead-stage lead-stage-${lead.stage}`}>
                          {pipelineStageLabels[lead.stage]}
                        </span>
                      </td>
                      <td>{lead.source_type}</td>
                      <td>{lead.assigned_name || "Sem responsável"}</td>
                      <td>{formatDate(lead.updated_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="empty-copy">
              Nenhuma Oportunidade visível nesta Operação.
            </p>
          )}
        </section>
      </main>
    </AppShell>
  );
}
