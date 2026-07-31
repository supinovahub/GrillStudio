import Link from "next/link";

import { BrandMark } from "@/components/brand-mark";
import {
  signOutAllSessionsAction,
  signOutCurrentAction,
  signOutOtherSessionsAction,
} from "@/lib/auth/actions";
import type { PreviewEnvironment } from "@/lib/environment";
import type { MemberWorkspace } from "@/types/database";

const managementNavigation = [
  ["Central", "/app/central"],
  ["Atendimentos", "/app/atendimentos"],
  ["Kanban", "/app/kanban"],
  ["Agenda", "/app/agenda"],
  ["Campanhas", "/app/campanhas"],
  ["Leads", "/app/leads"],
  ["Empreendimentos", "/app/empreendimentos"],
  ["Pedro", "/app/pedro"],
  ["Relatórios", "/app/relatorios"],
  ["Configurações", "/app/configuracoes/equipe"],
] as const;

const brokerNavigation = [
  ["Hoje", "/app/hoje"],
  ["Agenda", "/app/agenda"],
  ["Meu pipeline", "/app/meu-pipeline"],
  ["Atendimentos atribuídos", "/app/atendimentos"],
  ["Perfil", "/app/perfil"],
] as const;

function roleLabel(role: string) {
  return role === "owner" ? "Dono" : role === "manager" ? "Gestor" : "Corretor";
}

function roleSummary(workspace: MemberWorkspace) {
  return workspace.member_roles.map(roleLabel).join(" · ");
}

export function AppShell({
  activePath,
  children,
  environment,
  workspace,
}: Readonly<{
  activePath: string;
  children: React.ReactNode;
  environment: PreviewEnvironment;
  workspace: MemberWorkspace;
}>) {
  const hasManagementRole = workspace.member_roles.some((role) =>
    ["owner", "manager"].includes(role),
  );
  const availableManagementNavigation = workspace.can_manage_members
    ? managementNavigation
    : managementNavigation.filter(([label]) => label !== "Configurações");
  const navigation = hasManagementRole
    ? workspace.member_roles.includes("broker")
      ? [
          ...availableManagementNavigation.slice(0, 4),
          ["Meu pipeline", "/app/meu-pipeline"] as const,
          ...availableManagementNavigation.slice(4),
        ]
      : availableManagementNavigation
    : brokerNavigation;
  const pedroState = workspace.global_pause
    ? "Pausa global"
    : workspace.production_enabled
      ? "Produção"
      : "Produção desligada";

  return (
    <div className="app-shell">
      <aside className="sidebar" aria-label="Navegação principal">
        <div className="brand sidebar-brand">
          <BrandMark />
          <span>GrillStudio</span>
        </div>
        <div className="operation-switcher">
          <small>Imobiliária</small>
          <strong>{workspace.organization_name}</strong>
          <span>{workspace.operation_name}</span>
        </div>
        <nav>
          <ul>
            {navigation.map(([label, href]) => (
              <li key={href}>
                <Link
                  aria-current={href === activePath ? "page" : undefined}
                  className={
                    href === activePath ? "nav-link active" : "nav-link"
                  }
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
            <p>{workspace.operation_name}</p>
            <span>{workspace.organization_name}</span>
          </div>
          <div className="topbar-actions">
            <span
              className={`pedro-status ${workspace.global_pause ? "paused" : ""}`}
            >
              <span aria-hidden="true" />
              Pedro: {pedroState}
            </span>
            <details className="profile-menu">
              <summary>
                <span className="avatar" aria-hidden="true">
                  {roleLabel(workspace.member_role).slice(0, 1)}
                </span>
                <span>
                  <strong>{roleSummary(workspace)}</strong>
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

        {children}
      </div>

      <nav className="mobile-nav" aria-label="Navegação principal no celular">
        {navigation.slice(0, 4).map(([label, href]) => (
          <Link
            aria-current={href === activePath ? "page" : undefined}
            href={href}
            key={href}
          >
            {label}
          </Link>
        ))}
        <Link
          href={
            hasManagementRole ? "/app/configuracoes/equipe" : "/app/perfil"
          }
        >
          Mais
        </Link>
      </nav>
    </div>
  );
}
