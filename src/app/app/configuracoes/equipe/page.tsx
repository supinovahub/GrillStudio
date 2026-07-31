import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { appBaseUrl } from "@/lib/auth/redirects";
import { getPreviewEnvironment } from "@/lib/environment";
import { getMemberWorkspace } from "@/lib/operation/shell";
import {
  approveMembershipAction,
  createGeneralInvitationLinkAction,
  createIndividualInvitationAction,
  deactivateMembershipAction,
  regenerateGeneralInvitationLinkAction,
  setGeneralInvitationLinkStatusAction,
} from "@/lib/team/actions";
import { getTeamManagement } from "@/lib/team/queries";
import {
  managerPermissions,
  type MemberRole,
  type TeamMember,
} from "@/lib/team/types";

export const metadata: Metadata = {
  title: "Equipe e papéis",
};

type PageSearchParams = Promise<{
  resultado?: string;
}>;

const statusMessages: Record<string, string> = {
  "aprovacao-invalida": "Escolha ao menos um papel antes de aprovar.",
  "aprovacao-negada": "A aprovação foi recusada pelas regras de autoridade.",
  "cadastro-invalido": "Revise os dados informados.",
  "convite-criado": "Convite individual criado sem conceder acesso.",
  "convite-invalido": "Informe um e-mail e ao menos um papel.",
  "convite-negado": "Você não pode criar esse convite.",
  "desativacao-invalida":
    "Confirme o impacto e informe sua senha para desativar.",
  "desativacao-negada": "A desativação foi recusada.",
  "email-nao-confirmado":
    "O Membro precisa confirmar o e-mail antes da aprovação.",
  "link-criado": "Link geral criado. Todo cadastro continuará pendente.",
  "link-negado": "A alteração do link geral foi recusada.",
  "link-pausado": "Link geral pausado. O endereço não aceita cadastros.",
  "link-regenerado":
    "Link regenerado. O endereço anterior foi invalidado.",
  "link-retomado": "Link geral retomado.",
  "membro-aprovado": "Membro aprovado com os papéis e permissões escolhidos.",
  "membro-desativado":
    "Membro desativado, sessões revogadas e responsabilidades devolvidas.",
  "senha-incorreta": "A senha informada não confirmou sua identidade.",
};

function roleLabel(role: MemberRole): string {
  return role === "owner"
    ? "Dono"
    : role === "manager"
      ? "Gestor"
      : "Corretor";
}

function rolesLabel(roles: MemberRole[]): string {
  return roles.map(roleLabel).join(" · ");
}

function memberName(member: TeamMember): string {
  return member.full_name || member.email;
}

function canDeactivate(
  member: TeamMember,
  actorIsOwner: boolean,
  actorMembershipId: string,
): boolean {
  if (
    member.id === actorMembershipId ||
    member.status !== "active" ||
    member.roles.includes("owner")
  ) {
    return false;
  }

  return actorIsOwner || (
    member.roles.length === 1 && member.roles[0] === "broker"
  );
}

export default async function TeamPage({
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

  if (!workspace.can_manage_members) {
    redirect("/sem-permissao?recurso=equipe");
  }

  const team = await getTeamManagement(workspace.operation_id);
  const generalInvitationUrl = team.general_link
    ? `${appBaseUrl()}/convite/${team.general_link.token}`
    : null;
  const statusMessage = params.resultado
    ? statusMessages[params.resultado]
    : undefined;
  const pendingMembers = team.members.filter(
    (member) => member.status === "pending",
  );
  const activeMembers = team.members.filter(
    (member) => member.status === "active",
  );

  return (
    <AppShell
      activePath="/app/configuracoes/equipe"
      environment={environment}
      workspace={workspace}
    >
      <main className="central team-page" id="conteudo">
        {statusMessage ? (
          <p className="persistent-notice" role="status">
            {statusMessage}
          </p>
        ) : null}

        <section className="central-heading">
          <div>
            <p className="eyebrow">Configurações · Acesso</p>
            <h1>Equipe e papéis</h1>
            <p>
              Convide, aprove e desative Membros sem antecipar acesso nem
              ampliar a autoridade de quem executa a ação.
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Fronteira protegida</span>
            <strong>{environment.label}</strong>
            <span>{workspace.organization_name}</span>
            <small>Auth e RLS da Preview Branch</small>
          </div>
        </section>

        <div className="team-grid">
          <section className="team-panel" aria-labelledby="general-link-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Entrada controlada</p>
                <h2 id="general-link-title">Link geral da Imobiliária</h2>
              </div>
              {team.general_link ? (
                <span
                  className={
                    team.general_link.status === "active"
                      ? "safe-badge"
                      : "neutral-badge"
                  }
                >
                  {team.general_link.status === "active" ? "Ativo" : "Pausado"}
                </span>
              ) : null}
            </div>
            <p className="empty-copy">
              Qualquer cadastro por este endereço entra como Membro aguardando
              aprovação. O link não concede papel nem acesso.
            </p>

            {team.general_link && generalInvitationUrl ? (
              <>
                <div className="share-link">
                  <span>Endereço atual</span>
                  <Link href={`/convite/${team.general_link.token}`}>
                    {generalInvitationUrl}
                  </Link>
                </div>
                <div className="inline-actions">
                  <form action={setGeneralInvitationLinkStatusAction}>
                    <input
                      name="link_id"
                      type="hidden"
                      value={team.general_link.id}
                    />
                    <input
                      name="status"
                      type="hidden"
                      value={
                        team.general_link.status === "active"
                          ? "paused"
                          : "active"
                      }
                    />
                    <button className="button button-secondary" type="submit">
                      {team.general_link.status === "active"
                        ? "Pausar link"
                        : "Retomar link"}
                    </button>
                  </form>
                  <form action={regenerateGeneralInvitationLinkAction}>
                    <input
                      name="link_id"
                      type="hidden"
                      value={team.general_link.id}
                    />
                    <button className="button button-secondary" type="submit">
                      Regenerar endereço
                    </button>
                  </form>
                </div>
              </>
            ) : (
              <form action={createGeneralInvitationLinkAction}>
                <input
                  name="operation_id"
                  type="hidden"
                  value={workspace.operation_id}
                />
                <button className="button button-primary" type="submit">
                  Criar link geral
                </button>
              </form>
            )}
          </section>

          <section className="team-panel" aria-labelledby="individual-invite-title">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Convite individual</p>
                <h2 id="individual-invite-title">Predefina o papel</h2>
              </div>
            </div>
            <form
              action={createIndividualInvitationAction}
              className="form-stack compact-form"
            >
              <input
                name="operation_id"
                type="hidden"
                value={workspace.operation_id}
              />
              <div className="field">
                <label htmlFor="invite-email">E-mail do convite</label>
                <input
                  autoComplete="off"
                  id="invite-email"
                  name="email"
                  placeholder="corretor@example.com"
                  required
                  type="email"
                />
              </div>
              <fieldset className="choice-group">
                <legend>Papel predefinido</legend>
                {team.actor.is_owner ? (
                  <label className="check-field">
                    <input name="roles" type="checkbox" value="manager" />
                    <span>Gestor</span>
                  </label>
                ) : null}
                <label className="check-field">
                  <input
                    defaultChecked={!team.actor.is_owner}
                    name="roles"
                    type="checkbox"
                    value="broker"
                  />
                  <span>Corretor</span>
                </label>
              </fieldset>
              <button className="button button-primary" type="submit">
                Criar convite individual
              </button>
            </form>
          </section>
        </div>

        <section className="team-panel team-list" aria-labelledby="invites-title">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Ainda não cadastrados</p>
              <h2 id="invites-title">Convites individuais ativos</h2>
            </div>
            <span className="count-badge">{team.invitations.length}</span>
          </div>
          {team.invitations.length > 0 ? (
            <ul className="member-rows">
              {team.invitations.map((invitation) => (
                <li key={invitation.id}>
                  <div>
                    <strong>{invitation.email}</strong>
                    <span>
                      {rolesLabel(invitation.predefined_roles)} predefinido
                    </span>
                  </div>
                  <Link
                    className="text-link"
                    href={`/convite/${invitation.token}`}
                    aria-label={`Abrir convite de ${invitation.email}`}
                  >
                    Abrir convite
                  </Link>
                </li>
              ))}
            </ul>
          ) : (
            <p className="empty-copy">Nenhum convite individual ativo.</p>
          )}
        </section>

        <section className="team-panel team-list" aria-labelledby="pending-title">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Sem acesso</p>
              <h2 id="pending-title">Aguardando aprovação</h2>
            </div>
            <span className="count-badge">{pendingMembers.length}</span>
          </div>
          {pendingMembers.length > 0 ? (
            <div className="member-cards">
              {pendingMembers.map((member) => (
                <article className="member-card" key={member.id}>
                  <div className="member-summary">
                    <div>
                      <strong>{memberName(member)}</strong>
                      <span>{member.email}</span>
                    </div>
                    <span
                      className={
                        member.email_confirmed
                          ? "safe-badge"
                          : "neutral-badge"
                      }
                    >
                      {member.email_confirmed
                        ? "E-mail confirmado"
                        : "E-mail pendente"}
                    </span>
                  </div>
                  <p>
                    WhatsApp: {member.whatsapp ?? "não informado"} · Sugestão:{" "}
                    {member.predefined_roles.length > 0
                      ? rolesLabel(member.predefined_roles)
                      : "definir na aprovação"}
                  </p>
                  <details>
                    <summary className="button button-secondary">
                      Revisar e aprovar
                    </summary>
                    <form
                      action={approveMembershipAction}
                      className="approval-form"
                    >
                      <input
                        name="membership_id"
                        type="hidden"
                        value={member.id}
                      />
                      <input
                        name="operation_id"
                        type="hidden"
                        value={workspace.operation_id}
                      />
                      <fieldset className="choice-group">
                        <legend>Papéis</legend>
                        {team.actor.is_owner ? (
                          <label className="check-field">
                            <input
                              defaultChecked={member.predefined_roles.includes(
                                "manager",
                              )}
                              name="roles"
                              type="checkbox"
                              value="manager"
                            />
                            <span>Gestor</span>
                          </label>
                        ) : null}
                        <label className="check-field">
                          <input
                            defaultChecked={
                              !team.actor.is_owner ||
                              member.predefined_roles.includes("broker")
                            }
                            name="roles"
                            type="checkbox"
                            value="broker"
                          />
                          <span>Corretor</span>
                        </label>
                      </fieldset>
                      {team.actor.is_owner ? (
                        <fieldset className="permission-grid">
                          <legend>Permissões individuais de Gestor</legend>
                          {managerPermissions.map(([value, label]) => (
                            <label className="check-field" key={value}>
                              <input
                                name="permissions"
                                type="checkbox"
                                value={value}
                              />
                              <span>{label}</span>
                            </label>
                          ))}
                        </fieldset>
                      ) : null}
                      <button
                        className="button button-primary"
                        disabled={!member.email_confirmed}
                        type="submit"
                      >
                        Aprovar Membro
                      </button>
                    </form>
                  </details>
                </article>
              ))}
            </div>
          ) : (
            <p className="empty-copy">Nenhum cadastro aguarda aprovação.</p>
          )}
        </section>

        <section className="team-panel team-list" aria-labelledby="active-title">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Acesso atual</p>
              <h2 id="active-title">Membros ativos</h2>
            </div>
            <span className="count-badge">{activeMembers.length}</span>
          </div>
          <div className="member-cards">
            {activeMembers.map((member) => (
              <article className="member-card" key={member.id}>
                <div className="member-summary">
                  <div>
                    <strong>{memberName(member)}</strong>
                    <span>
                      {rolesLabel(member.roles)} · {member.email}
                    </span>
                  </div>
                  <span className="safe-badge">Ativo</span>
                </div>
                {member.permissions.length > 0 ? (
                  <p>{member.permissions.length} permissões individuais</p>
                ) : (
                  <p>Sem permissões administrativas adicionais.</p>
                )}

                {canDeactivate(
                  member,
                  team.actor.is_owner,
                  team.actor.membership_id,
                ) ? (
                  <details className="deactivation-details">
                    <summary className="button button-danger">
                      Ver impacto e desativar
                    </summary>
                    <form
                      action={deactivateMembershipAction}
                      className="approval-form danger-form"
                    >
                      <div className="impact-list">
                        <strong>Impacto antes da confirmação</strong>
                        <span>
                          {member.impact.future_calls} Calls futuras voltam à
                          distribuição
                        </span>
                        <span>
                          {member.impact.calls_within_one_hour} Calls em menos
                          de uma hora exigem atenção urgente
                        </span>
                        <span>
                          {member.impact.post_call_opportunities} Oportunidades
                          posteriores à Call ficam sem responsável
                        </span>
                        <span>Todas as sessões serão revogadas</span>
                      </div>
                      <input
                        name="membership_id"
                        type="hidden"
                        value={member.id}
                      />
                      <input
                        name="operation_id"
                        type="hidden"
                        value={workspace.operation_id}
                      />
                      <div className="field">
                        <label htmlFor={`password-${member.id}`}>
                          Confirme sua senha
                        </label>
                        <input
                          autoComplete="current-password"
                          id={`password-${member.id}`}
                          name="password"
                          required
                          type="password"
                        />
                      </div>
                      <label className="check-field">
                        <input
                          name="confirmation"
                          required
                          type="checkbox"
                        />
                        <span>
                          Entendo o impacto e quero desativar{" "}
                          {memberName(member)}.
                        </span>
                      </label>
                      <button className="button button-danger" type="submit">
                        Desativar Membro
                      </button>
                    </form>
                  </details>
                ) : null}
              </article>
            ))}
          </div>
        </section>
      </main>
    </AppShell>
  );
}
