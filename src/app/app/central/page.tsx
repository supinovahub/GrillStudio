import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { BrandMark } from "@/components/brand-mark";
import {
  signOutAllSessionsAction,
  signOutCurrentAction,
  signOutOtherSessionsAction,
} from "@/lib/auth/actions";
import { getPreviewEnvironment } from "@/lib/environment";
import { activateGlobalPauseAction } from "@/lib/operation/actions";
import { getOperationShell } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Central",
};

type PageSearchParams = Promise<{
  "kill-switch"?: string;
  sessao?: string;
}>;

const navigation = [
  ["Central", "/app/central"],
  ["Atendimentos", "/app/atendimentos"],
  ["Kanban", "/app/kanban"],
  ["Agenda", "/app/agenda"],
  ["Campanhas", "/app/campanhas"],
  ["Leads", "/app/leads"],
  ["Empreendimentos", "/app/empreendimentos"],
  ["Pedro", "/app/pedro"],
  ["Relatórios", "/app/relatorios"],
  ["Configurações", "/app/configuracoes"],
] as const;

function roleLabel(role: "owner" | "manager" | "broker") {
  return role === "owner" ? "Dono" : role === "manager" ? "Gestor" : "Corretor";
}

export default async function CentralPage({
  searchParams,
}: {
  searchParams: PageSearchParams;
}) {
  const [shell, environment, params] = await Promise.all([
    getOperationShell(),
    Promise.resolve(getPreviewEnvironment()),
    searchParams,
  ]);

  if (!shell) {
    redirect("/aguardando-aprovacao");
  }

  const pedroState = shell.global_pause
    ? "Pausa global"
    : shell.production_enabled
      ? "Produção"
      : "Produção desligada";

  const statusMessage =
    params["kill-switch"] === "acionado"
      ? "Kill switch acionado. Pedro está em pausa global."
      : params["kill-switch"] === "negado"
        ? "Você não tem permissão para acionar o kill switch."
        : params["kill-switch"] === "confirmacao-obrigatoria"
          ? "Confirme o impacto antes de acionar o kill switch."
          : params.sessao === "outras-encerradas"
            ? "As outras sessões foram encerradas."
            : params.sessao === "erro"
              ? "Não foi possível encerrar as outras sessões."
              : undefined;

  return (
    <div className="app-shell">
      <aside className="sidebar" aria-label="Navegação principal">
        <div className="brand sidebar-brand">
          <BrandMark />
          <span>GrillStudio</span>
        </div>
        <div className="operation-switcher">
          <small>Imobiliária</small>
          <strong>{shell.organization_name}</strong>
          <span>{shell.operation_name}</span>
        </div>
        <nav>
          <ul>
            {navigation.map(([label, href], index) => (
              <li key={href}>
                <Link
                  aria-current={index === 0 ? "page" : undefined}
                  className={index === 0 ? "nav-link active" : "nav-link"}
                  href={href}
                >
                  <span className="nav-marker" aria-hidden="true" />
                  {label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
        <div className="sidebar-environment">
          <span className="status-dot" aria-hidden="true" />
          <span>
            <strong>{environment.label}</strong>
            <small>Branch isolada</small>
          </span>
        </div>
      </aside>

      <div className="app-workspace">
        <header className="topbar">
          <div>
            <p>{shell.operation_name}</p>
            <span>{shell.organization_name}</span>
          </div>
          <div className="topbar-actions">
            <span className={`pedro-status ${shell.global_pause ? "paused" : ""}`}>
              <span aria-hidden="true" />
              Pedro: {pedroState}
            </span>
            <details className="profile-menu">
              <summary>
                <span className="avatar" aria-hidden="true">
                  D
                </span>
                <span>
                  <strong>{roleLabel(shell.member_role)}</strong>
                  <small>Perfil e sessões</small>
                </span>
              </summary>
              <div className="profile-menu-panel">
                <form action={signOutOtherSessionsAction}>
                  <button type="submit">Encerrar outras sessões</button>
                </form>
                <form action={signOutAllSessionsAction}>
                  <button type="submit">Encerrar todas as sessões</button>
                </form>
                <form action={signOutCurrentAction}>
                  <button type="submit">Sair deste dispositivo</button>
                </form>
              </div>
            </details>
          </div>
        </header>

        <main className="central" id="conteudo">
          {statusMessage ? (
            <p className="persistent-notice" role="status">
              {statusMessage}
            </p>
          ) : null}

          <section className="central-heading">
            <div>
              <p className="eyebrow">Central da Operação</p>
              <h1>O que precisa de você agora</h1>
              <p>
                Acompanhe riscos, decisões pendentes e o estado geral da
                Operação.
              </p>
            </div>
            <div className="environment-card">
              <span className="environment-kicker">Ambiente atual</span>
              <strong>{environment.label}</strong>
              <span>{environment.branchName}</span>
              <small>Dados sintéticos · sem egressos reais</small>
            </div>
          </section>

          <section className="status-strip" aria-label="Estado da Operação">
            <div>
              <span>Pedro</span>
              <strong>{pedroState}</strong>
            </div>
            <div>
              <span>Conversas ativas</span>
              <strong>0 de 30</strong>
            </div>
            <div>
              <span>Esperando</span>
              <strong>0</strong>
            </div>
            <div>
              <span>Saúde</span>
              <strong>Fundação segura</strong>
            </div>
          </section>

          <div className="central-grid">
            <section className="attention-panel" aria-labelledby="critical-title">
              <div className="section-heading">
                <div>
                  <span className="severity severity-critical">Crítico agora</span>
                  <h2 id="critical-title">Nenhum risco imediato</h2>
                </div>
                <span className="count-badge">0</span>
              </div>
              <p className="empty-copy">
                Calls sem responsável, erros críticos e alertas urgentes
                aparecerão aqui.
              </p>
            </section>

            <section className="attention-panel" aria-labelledby="action-title">
              <div className="section-heading">
                <div>
                  <span className="severity severity-action">Precisa de ação</span>
                  <h2 id="action-title">Tudo em dia</h2>
                </div>
                <span className="count-badge">0</span>
              </div>
              <p className="empty-copy">
                Escalonamentos, resultados ausentes e aprovações ficarão
                visíveis nesta fila.
              </p>
            </section>

            <section className="attention-panel wide" aria-labelledby="follow-title">
              <div className="section-heading">
                <div>
                  <span className="severity severity-follow">Acompanhar</span>
                  <h2 id="follow-title">Operação pronta para validação</h2>
                </div>
                <span className="count-badge">1</span>
              </div>
              <div className="follow-row">
                <div>
                  <strong>Preview Branch confirmada</strong>
                  <p>
                    Esta sessão usa exclusivamente a branch efêmera vinculada
                    ao PR #{environment.prNumber}.
                  </p>
                </div>
                <span className="safe-badge">Isolada</span>
              </div>
            </section>

            {shell.can_use_kill_switch ? (
              <section className="kill-switch-panel" aria-labelledby="kill-title">
                <div>
                  <p className="eyebrow">Contenção</p>
                  <h2 id="kill-title">Kill switch de Pedro</h2>
                  <p>
                    Interrompe imediatamente qualquer produção e mantém o
                    inbound disponível para atendimento humano.
                  </p>
                </div>
                {shell.global_pause ? (
                  <span className="pause-confirmed">Pausa global ativa</span>
                ) : (
                  <details>
                    <summary className="button button-danger">
                      Acionar kill switch
                    </summary>
                    <form action={activateGlobalPauseAction} className="impact-confirmation">
                      <input
                        name="operation_id"
                        type="hidden"
                        value={shell.operation_id}
                      />
                      <p>
                        Pedro será pausado em toda a Operação. Somente o Dono
                        poderá retomar após reautenticação e testes.
                      </p>
                      <label className="check-field">
                        <input name="confirmation" required type="checkbox" />
                        <span>Entendo o impacto desta contenção.</span>
                      </label>
                      <button className="button button-danger" type="submit">
                        Confirmar pausa global
                      </button>
                    </form>
                  </details>
                )}
              </section>
            ) : null}
          </div>
        </main>
      </div>

      <nav className="mobile-nav" aria-label="Navegação principal no celular">
        {navigation.slice(0, 4).map(([label, href], index) => (
          <Link
            aria-current={index === 0 ? "page" : undefined}
            href={href}
            key={href}
          >
            {label}
          </Link>
        ))}
        <Link href="/app/configuracoes">Mais</Link>
      </nav>
    </div>
  );
}
