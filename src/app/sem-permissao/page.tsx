import type { Metadata } from "next";
import Link from "next/link";

import { BrandMark } from "@/components/brand-mark";
import { signOutCurrentAction } from "@/lib/auth/actions";

export const metadata: Metadata = {
  title: "Sem permissão",
};

export default async function NoPermissionPage({
  searchParams,
}: {
  searchParams: Promise<{ recurso?: string }>;
}) {
  const resource = (await searchParams).recurso;
  const isTeam = resource === "equipe";

  return (
    <main className="centered-state" id="conteudo">
      <section className="state-panel" aria-labelledby="permission-title">
        <BrandMark />
        <p className="eyebrow">Acesso protegido</p>
        <h1 id="permission-title">
          {isTeam
            ? "A gestão da equipe não está disponível para este perfil"
            : "A Central não está disponível para este perfil"}
        </h1>
        <p>
          {isTeam
            ? "Somente o Dono e Gestores com a permissão Gerenciar Membros podem convidar, aprovar ou desativar a equipe."
            : "A Central de Operação e suas configurações são restritas a Donos e Gestores. Entre na área destinada ao seu perfil ou fale com o responsável pela Imobiliária."}
        </p>
        <Link className="button button-primary" href="/app/hoje">
          Ir para Hoje
        </Link>
        <form action={signOutCurrentAction}>
          <button className="button button-secondary" type="submit">
            Sair deste dispositivo
          </button>
        </form>
      </section>
    </main>
  );
}
