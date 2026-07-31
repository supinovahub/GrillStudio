import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { updatePasswordAction } from "@/lib/auth/actions";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Nova senha",
};

export default async function UpdatePasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ erro?: string }>;
}) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();

  if (error || !data?.claims) {
    redirect("/entrar?erro=link");
  }

  const hasPasswordError = params.erro === "senha";
  const unavailable = params.erro === "indisponivel";

  return (
    <div className="auth-card">
      <div className="auth-heading">
        <p className="eyebrow">Proteja seu acesso</p>
        <h2>Crie uma nova senha</h2>
        <p>A alteração encerrará todas as sessões abertas.</p>
      </div>

      {hasPasswordError || unavailable ? (
        <p className="form-notice form-notice-error" id="password-error" role="alert">
          {hasPasswordError
            ? "Use pelo menos 12 caracteres e repita a mesma senha."
            : "Não foi possível alterar a senha. Solicite um novo link."}
        </p>
      ) : null}

      <form action={updatePasswordAction} className="form-stack">
        <div className="field">
          <label htmlFor="password">Nova senha</label>
          <input
            aria-describedby="password-help password-error"
            aria-invalid={hasPasswordError || unavailable ? true : undefined}
            autoComplete="new-password"
            id="password"
            minLength={12}
            name="password"
            required
            type="password"
          />
          <small id="password-help">Mínimo de 12 caracteres.</small>
        </div>
        <div className="field">
          <label htmlFor="password_confirmation">Repita a nova senha</label>
          <input
            aria-describedby={hasPasswordError ? "password-error" : undefined}
            aria-invalid={hasPasswordError ? true : undefined}
            autoComplete="new-password"
            id="password_confirmation"
            minLength={12}
            name="password_confirmation"
            required
            type="password"
          />
        </div>
        <button className="button button-primary button-full" type="submit">
          Salvar nova senha
        </button>
      </form>
    </div>
  );
}
