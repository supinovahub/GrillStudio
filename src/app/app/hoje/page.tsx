import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { BrandMark } from "@/components/brand-mark";
import { signOutCurrentAction } from "@/lib/auth/actions";
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

  if (workspace.member_role !== "broker") {
    redirect("/app/central");
  }

  return (
    <main className="centered-state" id="conteudo">
      <section className="state-panel" aria-labelledby="today-title">
        <BrandMark />
        <p className="eyebrow">Hoje · Corretor</p>
        <h1 id="today-title">{workspace.operation_name}</h1>
        <p>
          {workspace.organization_name}. A fila comercial será disponibilizada
          em uma etapa posterior; esta entrega confirma somente o acesso
          isolado do Corretor.
        </p>
        <p>
          <strong>{environment.label}</strong>
          <br />
          Dados sintéticos · sem egressos reais
        </p>
        <form action={signOutCurrentAction}>
          <button className="button button-secondary" type="submit">
            Sair deste dispositivo
          </button>
        </form>
        <Link className="back-link" href="/sem-permissao">
          Entenda as permissões da Central
        </Link>
      </section>
    </main>
  );
}
