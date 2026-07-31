import type { Metadata } from "next";
import Link from "next/link";

import { BrandMark } from "@/components/brand-mark";
import { registerFromInvitationAction } from "@/lib/team/actions";
import { getInvitationEntry } from "@/lib/team/queries";

export const metadata: Metadata = {
  title: "Convite para a equipe",
};

type InvitationPageProps = {
  params: Promise<{ token: string }>;
  searchParams: Promise<{ resultado?: string }>;
};

const tokenPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export default async function InvitationPage({
  params,
  searchParams,
}: InvitationPageProps) {
  const [{ token }, query] = await Promise.all([params, searchParams]);
  const invitation = tokenPattern.test(token)
    ? await getInvitationEntry(token)
    : null;
  const activeInvitation = invitation?.link_status === "active";
  const waitingForConfirmation =
    query.resultado === "aguardando-confirmacao";
  const errorMessage =
    query.resultado === "cadastro-invalido"
      ? "Revise nome, e-mail, WhatsApp em E.164 e a senha de 12 caracteres."
      : query.resultado === "convite-indisponivel"
        ? "Este convite não está disponível para esse e-mail."
        : query.resultado === "cadastro-indisponivel"
          ? "Não foi possível concluir o cadastro. Nenhum acesso foi concedido."
          : undefined;

  return (
    <main className="invitation-stage" id="conteudo">
      <section className="invitation-card" aria-labelledby="invitation-title">
        <div className="brand">
          <BrandMark />
          <span>GrillStudio</span>
        </div>

        {waitingForConfirmation ? (
          <div className="invitation-state">
            <p className="eyebrow">Cadastro recebido</p>
            <h1 id="invitation-title">Confirme seu e-mail</h1>
            <p>
              Depois da confirmação, seu cadastro continuará como{" "}
              <strong>Aguardando aprovação</strong>. Nenhum dado da Imobiliária
              fica disponível antes da revisão de um responsável.
            </p>
            <Link className="button button-secondary" href="/entrar">
              Ir para a entrada
            </Link>
          </div>
        ) : activeInvitation ? (
          <>
            <div className="invitation-heading">
              <p className="eyebrow">
                {invitation.invitation_kind === "general"
                  ? "Link geral"
                  : "Convite individual"}
              </p>
              <h1 id="invitation-title">
                Entre para {invitation.organization_name}
              </h1>
              <p>
                O cadastro não concede acesso automático. Confirme seu e-mail e
                aguarde a aprovação do Dono ou Gestor autorizado.
              </p>
            </div>
            {errorMessage ? (
              <p className="form-notice form-notice-error" role="alert">
                {errorMessage}
              </p>
            ) : null}
            <form
              action={registerFromInvitationAction}
              className="form-stack"
            >
              <input name="token" type="hidden" value={token} />
              <div className="field">
                <label htmlFor="invitation-name">Nome completo</label>
                <input
                  autoComplete="name"
                  id="invitation-name"
                  name="full_name"
                  required
                />
              </div>
              <div className="field">
                <label htmlFor="invitation-email">E-mail</label>
                <input
                  autoComplete="email"
                  id="invitation-email"
                  name="email"
                  required
                  type="email"
                />
              </div>
              <div className="field">
                <label htmlFor="invitation-whatsapp">WhatsApp</label>
                <input
                  autoComplete="tel"
                  id="invitation-whatsapp"
                  name="whatsapp"
                  pattern="\+[1-9][0-9]{7,14}"
                  placeholder="+5511999999999"
                  required
                  type="tel"
                />
                <small>Use o formato internacional com código do país.</small>
              </div>
              <div className="field">
                <label htmlFor="invitation-password">Senha</label>
                <input
                  autoComplete="new-password"
                  id="invitation-password"
                  minLength={12}
                  name="password"
                  required
                  type="password"
                />
              </div>
              <div className="field">
                <label htmlFor="invitation-password-confirmation">
                  Repita a senha
                </label>
                <input
                  autoComplete="new-password"
                  id="invitation-password-confirmation"
                  minLength={12}
                  name="password_confirmation"
                  required
                  type="password"
                />
              </div>
              <button className="button button-primary" type="submit">
                Cadastrar e confirmar e-mail
              </button>
            </form>
          </>
        ) : (
          <div className="invitation-state">
            <p className="eyebrow">Convite indisponível</p>
            <h1 id="invitation-title">Este endereço não aceita cadastros</h1>
            <p>
              O link foi pausado, regenerado, utilizado ou revogado. Solicite
              um endereço atual ao responsável pela Imobiliária.
            </p>
            <Link className="button button-secondary" href="/entrar">
              Voltar para a entrada
            </Link>
          </div>
        )}
      </section>
    </main>
  );
}
