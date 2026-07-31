import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { AppShell } from "@/components/app-shell";
import { getPreviewEnvironment } from "@/lib/environment";
import { getMemberWorkspace } from "@/lib/operation/shell";

export const metadata: Metadata = {
  title: "Hoje",
};

export default async function TodayPage() {
  const [workspace, environment] = await Promise.all([
    getMemberWorkspace(),
    Promise.resolve(getPreviewEnvironment()),
  ]);

  if (!workspace) {
    redirect("/aguardando-aprovacao");
  }

  if (!workspace.member_roles.includes("broker")) {
    redirect("/app/central");
  }

  return (
    <AppShell activePath="/app/hoje" environment={environment} workspace={workspace}>
      <main className="central" id="conteudo">
        <section className="central-heading">
          <div>
            <p className="eyebrow">Hoje · Corretor</p>
            <h1>{workspace.operation_name}</h1>
            <p>
              {workspace.organization_name}. A fila comercial será
              disponibilizada em uma etapa posterior; esta entrega confirma
              somente o acesso isolado do Corretor.
            </p>
          </div>
          <div className="environment-card">
            <span className="environment-kicker">Ambiente atual</span>
            <strong>{environment.label}</strong>
            <span>{environment.branchName}</span>
            <small>Dados sintéticos · sem egressos reais</small>
          </div>
        </section>
      </main>
    </AppShell>
  );
}
