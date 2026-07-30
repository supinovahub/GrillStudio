import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { BrandMark } from "@/components/brand-mark";
import { signOutCurrentAction } from "@/lib/auth/actions";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Aguardando aprovação",
};

export default async function WaitingForApprovalPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();

  if (error || !data?.claims) {
    redirect("/entrar");
  }

  return (
    <main className="centered-state" id="conteudo">
      <div className="state-panel">
        <BrandMark />
        <p className="eyebrow">Acesso confirmado</p>
        <h1>Aguardando aprovação</h1>
        <p>
          Seu e-mail foi confirmado, mas nenhum acesso ativo a uma Imobiliária
          foi encontrado. O Dono ou Gestor precisa concluir a aprovação.
        </p>
        <form action={signOutCurrentAction}>
          <button className="button button-secondary" type="submit">
            Sair deste dispositivo
          </button>
        </form>
      </div>
    </main>
  );
}
