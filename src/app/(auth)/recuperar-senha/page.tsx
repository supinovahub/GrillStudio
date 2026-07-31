import type { Metadata } from "next";
import Link from "next/link";

import { requestPasswordResetAction } from "@/lib/auth/actions";

export const metadata: Metadata = {
  title: "Recuperar senha",
};

export default async function RecoverPasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ enviado?: string; erro?: string }>;
}) {
  const params = await searchParams;
  const sent = params.enviado === "1";
  const error = params.erro === "campos";

  return (
    <div className="auth-card">
      <div className="auth-heading">
        <p className="eyebrow">Recuperação de acesso</p>
        <h2>Redefina sua senha</h2>
        <p>
          Enviaremos as instruções se o endereço pertencer a um Membro
          cadastrado.
        </p>
      </div>

      {sent ? (
        <p className="form-notice form-notice-success" role="status">
          Se o e-mail estiver cadastrado, as instruções chegarão em instantes.
        </p>
      ) : (
        <form action={requestPasswordResetAction} className="form-stack">
          {error ? (
            <p className="form-notice form-notice-error" id="email-error" role="alert">
              Informe seu e-mail.
            </p>
          ) : null}
          <div className="field">
            <label htmlFor="email">E-mail</label>
            <input
              aria-describedby={error ? "email-error" : "email-help"}
              aria-invalid={error ? true : undefined}
              autoComplete="email"
              id="email"
              inputMode="email"
              name="email"
              required
              type="email"
            />
            <small id="email-help">Use o endereço do seu acesso atual.</small>
          </div>
          <button className="button button-primary button-full" type="submit">
            Enviar instruções
          </button>
        </form>
      )}

      <Link className="back-link" href="/entrar">
        Voltar para entrar
      </Link>
    </div>
  );
}
