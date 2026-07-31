import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { getPreviewEnvironment } from "@/lib/environment";
import { activateGlobalPauseAction } from "@/lib/operation/actions";
import { getMemberWorkspace, getOperationShell } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Central",
};

type PageSearchParams = Promise<{
  "kill-switch"?: string;
  sessao?: string;
}>;

function roleLabel(role: "owner" | "manager" | "broker") {
  return role === "owner" ? "Dono" : role === "manager" ? "Gestor" : "Corretor";
}

export default async function CentralPage({
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

  if (workspace.member_role === "broker") {
    redirect("/sem-permissao");
  }

  const shell = await getOperationShell();
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
    <AppShell
      activePath="/app/central"
      environment={environment}
      workspace={workspace}
    >
      <main className="central" id="conteudo">
        {statusMessage ? (
          <p className="persistent-notice" role="status">
            {statusMessage}
          </p>
        ) : null}

        <section className="central-heading">
          <div>
            <p className="eyebrow">Central da Operação</p>
            <h1>Fundação da Operação</h1>
            <p>
              Confirme a identidade, o ambiente e o estado de Pedro antes de
              iniciar qualquer fluxo comercial.
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
            <span>Imobiliária</span>
            <strong>{shell.organization_name}</strong>
          </div>
          <div>
            <span>Operação</span>
            <strong>{shell.operation_name}</strong>
          </div>
          <div>
            <span>Perfil</span>
            <strong>{roleLabel(shell.member_role)}</strong>
          </div>
          <div>
            <span>Pedro</span>
            <strong>{pedroState}</strong>
          </div>
        </section>

        <div className="central-grid">
          <section className="attention-panel wide" aria-labelledby="boundary-title">
            <div className="section-heading">
              <div>
                <span className="severity severity-follow">
                  Limite da execução
                </span>
                <h2 id="boundary-title">
                  Preview Branch do PR #{environment.prNumber}
                </h2>
              </div>
              <span className="safe-badge">Isolada</span>
            </div>
            <p className="empty-copy">
              O servidor recusa a inicialização se a referência do projeto, a
              branch ou o número do PR não coincidirem. Esta interface não
              informa métricas comerciais que ainda não foram carregadas de
              uma fonte canônica.
            </p>
          </section>

          {shell.can_use_kill_switch ? (
            <section className="kill-switch-panel" aria-labelledby="kill-title">
              <div>
                <p className="eyebrow">Contenção</p>
                <h2 id="kill-title">Kill switch de Pedro</h2>
                <p>
                  Interrompe imediatamente qualquer produção e mantém o inbound
                  disponível para atendimento humano.
                </p>
              </div>
              {shell.global_pause ? (
                <span className="pause-confirmed">Pausa global ativa</span>
              ) : (
                <details>
                  <summary className="button button-danger">
                    Acionar kill switch
                  </summary>
                  <form
                    action={activateGlobalPauseAction}
                    className="impact-confirmation"
                  >
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
    </AppShell>
  );
}
