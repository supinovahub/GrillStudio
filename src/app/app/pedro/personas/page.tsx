import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import {
  archiveContextDraftAction,
  createContextDraftAction,
  initializeContextAction,
  publishContextAction,
  saveInstitutionalDraftAction,
  savePersonaDraftAction,
  setContextProductionAction,
  validateContextAction,
} from "@/lib/context/actions";
import { getContextWorkspace } from "@/lib/context/queries";
import {
  institutionalFields,
  type BehavioralDraft,
  type ContextDraft,
  type FactualDraft,
} from "@/lib/context/types";
import { getPreviewEnvironment } from "@/lib/environment";
import { getMemberWorkspace } from "@/lib/operation/shell";
import type { Json } from "@/types/database";

export const metadata: Metadata = {
  title: "Contexto inicial do Pedro",
};

type PageSearchParams = Promise<{ resultado?: string }>;

const statusMessages: Record<string, string> = {
  "arquivamento-negado": "O rascunho não pôde ser arquivado.",
  "contexto-publicado":
    "Contexto publicado. As versões factual e comportamental ficaram imutáveis.",
  "institucional-salvo": "Perfil institucional salvo como rascunho.",
  "pacote-preparado":
    "Pacote inicial preparado sem presumir fatos da sua Operação.",
  "persona-invalida": "Revise o conteúdo da Persona.",
  "persona-negada": "A Persona não pôde ser salva com a sua autoridade atual.",
  "persona-salva": "Identidade, biografia e estilo salvos como rascunho.",
  "preparo-negado": "Você não pode preparar o Contexto desta Operação.",
  "producao-bloqueada":
    "Modo produção permanece desligado. Resolva os bloqueios publicados.",
  "producao-confirmacao-obrigatoria":
    "Confirme o impacto e informe sua senha.",
  "producao-desligada": "Modo produção desligado.",
  "producao-habilitada": "Modo produção habilitado pelo Dono.",
  "publicacao-negada":
    "A publicação foi negada. Valide o diff e confira sua autoridade.",
  "rascunho-arquivado": "Rascunho arquivado sem alterar a versão publicada.",
  "rascunho-criado": "Nova versão criada a partir do Contexto publicado.",
  "rascunho-negado": "Não foi possível criar uma nova versão.",
  "salvamento-negado":
    "O perfil não foi salvo. Atualize a página e confira as permissões.",
  "senha-incorreta": "A senha informada não confirmou sua identidade.",
  "validacao-aprovada": "Validação concluída. Revise o diff antes de publicar.",
  "validacao-negada": "A validação foi negada.",
  "validacao-pendente":
    "A validação encontrou pendências. Corrija os campos indicados.",
};

function text(value: Json | undefined): string {
  return typeof value === "string" ? value : "";
}

function flag(value: Json | undefined): boolean {
  return value === true;
}

function DraftIds({
  behavioral,
  factual,
  operationId,
}: {
  behavioral: BehavioralDraft;
  factual: FactualDraft;
  operationId: string;
}) {
  return (
    <>
      <input name="operation_id" type="hidden" value={operationId} />
      <input
        name="factual_version_id"
        type="hidden"
        value={factual.id}
      />
      <input
        name="factual_expected_version"
        type="hidden"
        value={factual.version}
      />
      <input
        name="behavioral_version_id"
        type="hidden"
        value={behavioral.id}
      />
      <input
        name="behavioral_expected_version"
        type="hidden"
        value={behavioral.version}
      />
    </>
  );
}

function VersionBadge({
  draft,
  label,
}: {
  draft: ContextDraft;
  label: string;
}) {
  return (
    <span className={`context-version-badge ${draft.status}`}>
      {label} v{draft.version_number} ·{" "}
      {draft.status === "validating" ? "Em validação" : "Rascunho"}
    </span>
  );
}

function ValidationBlock({
  behavioral,
  factual,
}: {
  behavioral: BehavioralDraft;
  factual: FactualDraft;
}) {
  const errors = [
    ...factual.validation_errors,
    ...behavioral.validation_errors,
  ];
  if (factual.status !== "validating" && behavioral.status !== "validating") {
    return null;
  }

  return (
    <section className="context-validation" aria-live="polite">
      <div>
        <p className="eyebrow">Validação e diff</p>
        <h2>
          {errors.length === 0
            ? "Pronto para decisão de publicação"
            : `${errors.length} pendência(s) encontrada(s)`}
        </h2>
      </div>
      {errors.length > 0 ? (
        <ul>
          {errors.map((error) => (
            <li key={error}>{error}</li>
          ))}
        </ul>
      ) : (
        <p>
          Os hashes foram calculados e o conteúdo abaixo é exatamente o que
          ficará reproduzível.
        </p>
      )}
      <details>
        <summary>Ver diff factual</summary>
        <pre>{JSON.stringify(factual.diff_snapshot, null, 2)}</pre>
      </details>
      <details>
        <summary>Ver diff comportamental</summary>
        <pre>{JSON.stringify(behavioral.diff_snapshot, null, 2)}</pre>
      </details>
    </section>
  );
}

export default async function PersonaContextPage({
  searchParams,
}: {
  searchParams: PageSearchParams;
}) {
  const workspace = await getMemberWorkspace();
  if (!workspace) {
    redirect("/aguardando-aprovacao");
  }

  const canRead =
    workspace.member_roles.includes("owner") ||
    workspace.member_permissions.some((permission) =>
      ["publish_knowledge", "train_pedro", "publish_learning"].includes(
        permission,
      ),
    );
  if (!canRead) {
    redirect("/sem-permissao");
  }

  const context = await getContextWorkspace(workspace.operation_id);
  const { resultado } = await searchParams;
  const factual = context.factual_draft;
  const behavioral = context.behavioral_draft;

  return (
    <AppShell
      activePath="/app/pedro/personas"
      environment={getPreviewEnvironment()}
      workspace={workspace}
    >
      <main className="page-content context-page">
        <header className="page-header context-header">
          <div>
            <p className="eyebrow">Pedro · Contexto publicado</p>
            <h1>Perfil institucional e Persona</h1>
            <p>
              Separe fatos da Operação do comportamento do Pedro, valide o
              diff e publique snapshots reproduzíveis.
            </p>
          </div>
          <div className="context-header-status">
            <span
              className={
                context.active_publication
                  ? "context-publication-status published"
                  : "context-publication-status"
              }
            >
              {context.active_publication
                ? `Publicação #${context.active_publication.publication_number}`
                : "Nenhum Contexto publicado"}
            </span>
            <span
              className={
                context.production_enabled
                  ? "context-production-status enabled"
                  : "context-production-status"
              }
            >
              Produção {context.production_enabled ? "habilitada" : "desligada"}
            </span>
          </div>
        </header>

        {resultado && statusMessages[resultado] ? (
          <div className="status-banner" role="status">
            {statusMessages[resultado]}
          </div>
        ) : null}

        {!factual || !behavioral ? (
          <section className="empty-state context-empty">
            <p className="eyebrow">
              {context.active_publication ? "Nova versão" : "Primeiro acesso"}
            </p>
            <h2>
              {context.active_publication
                ? "O Contexto publicado continua protegido"
                : "Prepare o pacote inicial do Pedro"}
            </h2>
            <p>
              {context.active_publication
                ? "Crie rascunhos clonados para propor mudanças sem editar o histórico."
                : "O pacote inclui somente regras e estilo aprovados. CRECI, experiência e fatos da Operação começam vazios."}
            </p>
            <form
              action={
                context.active_publication
                  ? createContextDraftAction
                  : initializeContextAction
              }
            >
              <input
                name="operation_id"
                type="hidden"
                value={workspace.operation_id}
              />
              <button className="primary-button" type="submit">
                {context.active_publication
                  ? "Criar nova versão"
                  : "Preparar pacote inicial"}
              </button>
            </form>
          </section>
        ) : (
          <>
            <section className="context-version-strip">
              <VersionBadge draft={factual} label="Factual" />
              <VersionBadge draft={behavioral} label="Comportamental" />
              <span>
                Uma publicação une os dois IDs, mas cada versão conserva seu
                próprio conteúdo e hash.
              </span>
            </section>

            <form
              action={saveInstitutionalDraftAction}
              className="context-editor institutional-editor"
            >
              <DraftIds
                behavioral={behavioral}
                factual={factual}
                operationId={workspace.operation_id}
              />
              <header>
                <div>
                  <p className="eyebrow">Versão factual</p>
                  <h2>Perfil institucional</h2>
                  <p>
                    Pedro só divulga um campo conforme a permissão registrada.
                    Fonte, conferência e validade acompanham o valor.
                  </p>
                </div>
                <button
                  className="secondary-button"
                  disabled={!context.actor.can_edit_institutional}
                  type="submit"
                >
                  Salvar perfil
                </button>
              </header>

              <div className="institutional-fields">
                {institutionalFields.map(([key, label, description]) => {
                  const value = factual.fields[key];
                  return (
                    <fieldset className="institutional-field" key={key}>
                      <legend>{label}</legend>
                      <p>{description}</p>
                      <label>
                        Valor
                        <input
                          defaultValue={value?.value ?? ""}
                          name={`${key}_value`}
                          readOnly={!context.actor.can_edit_institutional}
                        />
                      </label>
                      <div className="institutional-field-grid">
                        <label>
                          Fonte
                          <input
                            defaultValue={value?.source ?? ""}
                            name={`${key}_source`}
                            placeholder="Ex.: contrato social, site do CRECI"
                            readOnly={!context.actor.can_edit_institutional}
                          />
                        </label>
                        <label>
                          Data da conferência
                          <input
                            defaultValue={value?.confirmed_at ?? ""}
                            name={`${key}_confirmed_at`}
                            readOnly={!context.actor.can_edit_institutional}
                            type="date"
                          />
                        </label>
                        <label>
                          Validade
                          <input
                            defaultValue={value?.valid_until ?? ""}
                            name={`${key}_valid_until`}
                            readOnly={!context.actor.can_edit_institutional}
                            type="date"
                          />
                          <small>Deixe vazio quando não houver validade.</small>
                        </label>
                        <label>
                          Divulgação
                          <select
                            defaultValue={value?.disclosure ?? "on_request"}
                            disabled={!context.actor.can_edit_institutional}
                            name={`${key}_disclosure`}
                          >
                            <option value="on_request">
                              Somente quando solicitado
                            </option>
                            <option value="when_needed">
                              Quando necessário para legitimidade
                            </option>
                            <option value="never">Nunca divulgar</option>
                          </select>
                        </label>
                      </div>
                      <label>
                        Link público de consulta
                        <input
                          defaultValue={value?.public_source_url ?? ""}
                          name={`${key}_public_source_url`}
                          placeholder="Opcional"
                          readOnly={!context.actor.can_edit_institutional}
                          type="url"
                        />
                      </label>
                      <label className="institutional-confirmation">
                        <input
                          defaultChecked={value?.confirmed_by_owner ?? false}
                          disabled={!context.actor.is_owner}
                          name={`${key}_confirmed_by_owner`}
                          type="checkbox"
                        />
                        Informado e confirmado pelo dono
                      </label>
                    </fieldset>
                  );
                })}
              </div>
            </form>

            <form
              action={savePersonaDraftAction}
              className="context-editor persona-editor"
            >
              <DraftIds
                behavioral={behavioral}
                factual={factual}
                operationId={workspace.operation_id}
              />
              <input
                name="persona_instructions"
                type="hidden"
                value={JSON.stringify(behavioral.instructions)}
              />
              <header>
                <div>
                  <p className="eyebrow">Versão comportamental</p>
                  <h2>Identidade, biografia e estilo</h2>
                  <p>
                    Campos vazios permanecem desconhecidos. O pacote nunca
                    presume experiência, CRECI ou acontecimentos pessoais.
                  </p>
                </div>
                <button
                  className="secondary-button"
                  disabled={!context.actor.can_edit_persona}
                  type="submit"
                >
                  Salvar Persona
                </button>
              </header>

              <div className="persona-section">
                <h3>Identidade</h3>
                {!context.actor.is_owner ? (
                  <p className="context-permission-note">
                    Somente o Dono altera a identidade. Você pode preparar
                    biografia e estilo conforme sua permissão.
                  </p>
                ) : null}
                <div className="persona-grid">
                  <label>
                    Nome completo
                    <input
                      defaultValue={text(behavioral.identity.full_name)}
                      name="persona_full_name"
                      readOnly={!context.actor.is_owner}
                    />
                  </label>
                  <label>
                    Função
                    <input
                      defaultValue={text(
                        behavioral.identity.professional_role,
                      )}
                      name="persona_professional_role"
                      readOnly={!context.actor.is_owner}
                    />
                  </label>
                  <label>
                    Cidade
                    <input
                      defaultValue={text(behavioral.identity.city)}
                      name="persona_city"
                      readOnly={!context.actor.is_owner}
                    />
                  </label>
                  <label>
                    CRECI
                    <input
                      defaultValue={text(behavioral.identity.creci)}
                      name="persona_creci"
                      readOnly={!context.actor.is_owner}
                    />
                  </label>
                  <label>
                    UF do CRECI
                    <input
                      defaultValue={text(behavioral.identity.creci_uf)}
                      maxLength={2}
                      name="persona_creci_uf"
                      readOnly={!context.actor.is_owner}
                    />
                  </label>
                  <label className="persona-check">
                    {context.actor.is_owner ? (
                      <input
                        defaultChecked={flag(
                          behavioral.identity.presents_as_broker,
                        )}
                        name="persona_presents_as_broker"
                        type="checkbox"
                      />
                    ) : (
                      <>
                        <input
                          name="persona_presents_as_broker"
                          type="hidden"
                          value={
                            flag(behavioral.identity.presents_as_broker)
                              ? "on"
                              : ""
                          }
                        />
                        <input
                          aria-label="Apresenta-se como Corretor"
                          checked={flag(
                            behavioral.identity.presents_as_broker,
                          )}
                          disabled
                          readOnly
                          type="checkbox"
                        />
                      </>
                    )}
                    Apresenta-se como Corretor
                  </label>
                </div>
              </div>

              <div className="persona-section">
                <h3>Biografia autorizada</h3>
                <div className="persona-grid">
                  <label>
                    Experiência profissional
                    <textarea
                      defaultValue={text(
                        behavioral.biography.professional_experience,
                      )}
                      name="persona_professional_experience"
                      readOnly={!context.actor.can_edit_persona}
                    />
                  </label>
                  <label>
                    Interesses
                    <textarea
                      defaultValue={text(behavioral.biography.interests)}
                      name="persona_interests"
                      readOnly={!context.actor.can_edit_persona}
                    />
                  </label>
                  <label>
                    Time
                    <input
                      defaultValue={text(behavioral.biography.team)}
                      name="persona_team"
                      readOnly={!context.actor.can_edit_persona}
                    />
                  </label>
                  <label>
                    Rotina aprovada
                    <textarea
                      defaultValue={text(
                        behavioral.biography.approved_routine,
                      )}
                      name="persona_approved_routine"
                      readOnly={!context.actor.can_edit_persona}
                    />
                  </label>
                </div>
              </div>

              <div className="persona-section">
                <h3>Estilo</h3>
                <label>
                  Tom de voz
                  <input
                    defaultValue={text(behavioral.style_rules.tone)}
                    name="persona_tone"
                    readOnly={!context.actor.can_edit_persona}
                  />
                </label>
                <label className="persona-check">
                  <input
                    defaultChecked={flag(
                      behavioral.style_rules.humor_after_rapport,
                    )}
                    disabled={!context.actor.can_edit_persona}
                    name="persona_humor_after_rapport"
                    type="checkbox"
                  />
                  Humor e `kkk` somente depois de conexão com o lead
                </label>
                <div className="persona-guardrails">
                  <span>pt-BR</span>
                  <span>Uma pergunta por vez</span>
                  <span>Nunca inventar experiência pessoal</span>
                  <span>Escalonamento silencioso quando obrigatório</span>
                </div>
              </div>
            </form>

            <ValidationBlock behavioral={behavioral} factual={factual} />

            <section className="context-actions">
              <div>
                <p className="eyebrow">Fluxo de publicação</p>
                <h2>Validar, revisar o diff e decidir</h2>
                <p>
                  Publicar cria novos snapshots; não altera mensagens ou
                  versões anteriores.
                </p>
              </div>
              <div className="context-action-buttons">
                <form action={validateContextAction}>
                  <DraftIds
                    behavioral={behavioral}
                    factual={factual}
                    operationId={workspace.operation_id}
                  />
                  <button className="secondary-button" type="submit">
                    Validar e gerar diff
                  </button>
                </form>
                <form action={publishContextAction}>
                  <DraftIds
                    behavioral={behavioral}
                    factual={factual}
                    operationId={workspace.operation_id}
                  />
                  <button
                    className="primary-button"
                    disabled={
                      behavioral.status !== "validating" ||
                      factual.status !== "validating" ||
                      behavioral.validation_errors.length > 0 ||
                      factual.validation_errors.length > 0
                    }
                    type="submit"
                  >
                    Publicar Contexto
                  </button>
                </form>
                <form action={archiveContextDraftAction}>
                  <DraftIds
                    behavioral={behavioral}
                    factual={factual}
                    operationId={workspace.operation_id}
                  />
                  <button className="text-button danger" type="submit">
                    Arquivar rascunhos
                  </button>
                </form>
              </div>
            </section>
          </>
        )}

        <section className="context-readiness">
          <div>
            <p className="eyebrow">Portão de produção</p>
            <h2>
              {context.readiness.ready
                ? "Contexto obrigatório completo"
                : "Produção continua bloqueada"}
            </h2>
            <p>
              O portão consulta somente a publicação ativa. Campos opcionais
              geram alertas, não bloqueios.
            </p>
          </div>
          <div className="context-readiness-columns">
            <div>
              <h3>Bloqueios</h3>
              {context.readiness.errors.length ? (
                <ul>
                  {context.readiness.errors.map((error) => (
                    <li key={error}>{error}</li>
                  ))}
                </ul>
              ) : (
                <p>Nenhum bloqueio obrigatório.</p>
              )}
            </div>
            <div>
              <h3>Alertas</h3>
              {context.readiness.warnings.length ? (
                <ul>
                  {context.readiness.warnings.map((warning) => (
                    <li key={warning}>{warning}</li>
                  ))}
                </ul>
              ) : (
                <p>Nenhum alerta de completude.</p>
              )}
            </div>
          </div>
          {context.actor.is_owner ? (
            <form
              action={setContextProductionAction}
              className="context-production-form"
            >
              <input
                name="operation_id"
                type="hidden"
                value={workspace.operation_id}
              />
              <input
                name="enable_production"
                type="hidden"
                value={context.production_enabled ? "false" : "true"}
              />
              <label>
                Confirme sua senha
                <input
                  autoComplete="current-password"
                  name="password"
                  required
                  type="password"
                />
              </label>
              <label className="persona-check">
                <input name="confirmation" required type="checkbox" />
                Entendo que esta ação altera o atendimento autônomo da Operação
              </label>
              <button
                className={
                  context.production_enabled
                    ? "secondary-button"
                    : "primary-button"
                }
                type="submit"
              >
                {context.production_enabled
                  ? "Desligar IA em produção"
                  : "Habilitar IA em produção"}
              </button>
            </form>
          ) : (
            <p className="context-permission-note">
              Somente o Dono habilita ou desliga o Modo produção.
            </p>
          )}
        </section>

        <section className="context-history">
          <header>
            <p className="eyebrow">Histórico imutável</p>
            <h2>Publicações</h2>
          </header>
          {context.history.length ? (
            <ol>
              {context.history.map((publication) => (
                <li key={publication.id}>
                  <div>
                    <strong>Publicação #{publication.publication_number}</strong>
                    <span>
                      {new Intl.DateTimeFormat("pt-BR", {
                        dateStyle: "medium",
                        timeStyle: "short",
                      }).format(new Date(publication.published_at))}
                    </span>
                  </div>
                  <code>{publication.combined_hash.slice(0, 16)}…</code>
                  <small>
                    Factual {publication.factual_version_id.slice(0, 8)} ·
                    Comportamental{" "}
                    {publication.behavioral_version_id.slice(0, 8)}
                  </small>
                </li>
              ))}
            </ol>
          ) : (
            <p>Nenhuma publicação criada.</p>
          )}
        </section>
      </main>
    </AppShell>
  );
}
