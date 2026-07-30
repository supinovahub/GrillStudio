import type { Metadata } from "next";
import Link from "next/link";

import { signInAction } from "@/lib/auth/actions";
import { safeInternalPath } from "@/lib/auth/redirects";

export const metadata: Metadata = {
  title: "Entrar",
};

type SearchParams = Promise<{
  erro?: string;
  next?: string;
  senha?: string;
  sessao?: string;
}>;

const errorMessages: Record<string, string> = {
  campos: "Informe e-mail e senha para continuar.",
  credenciais: "E-mail ou senha não conferem.",
  link: "Este link não é válido ou já expirou.",
};

export default async function SignInPage({
  searchParams,
}: {
  searchParams: SearchParams;
}) {
  const params = await searchParams;
  const error = params.erro ? errorMessages[params.erro] : undefined;
  const success =
    params.senha === "alterada"
      ? "Senha atualizada. Entre novamente com a nova senha."
      : params.sessao === "encerrada"
        ? "Todas as suas sessões foram encerradas."
        : undefined;

  return (
    <div className="auth-card">
      <div className="auth-heading">
        <p className="eyebrow">Acesso seguro</p>
        <h2>Entre na sua Operação</h2>
        <p>Use o e-mail confirmado da sua Imobiliária.</p>
      </div>

      {error ? (
        <p className="form-notice form-notice-error" id="form-error" role="alert">
          {error}
        </p>
      ) : null}
      {success ? (
        <p className="form-notice form-notice-success" role="status">
          {success}
        </p>
      ) : null}

      <form action={signInAction} className="form-stack">
        <input
          name="next"
          type="hidden"
          value={safeInternalPath(params.next)}
        />
        <div className="field">
          <label htmlFor="email">E-mail</label>
          <input
            aria-describedby={error ? "form-error" : undefined}
            aria-invalid={error ? true : undefined}
            autoComplete="email"
            id="email"
            inputMode="email"
            name="email"
            placeholder="voce@imobiliaria.com.br"
            required
            type="email"
          />
        </div>
        <div className="field">
          <div className="label-row">
            <label htmlFor="password">Senha</label>
            <Link href="/recuperar-senha">Esqueci minha senha</Link>
          </div>
          <input
            aria-describedby={error ? "form-error" : undefined}
            aria-invalid={error ? true : undefined}
            autoComplete="current-password"
            id="password"
            name="password"
            required
            type="password"
          />
        </div>
        <button className="button button-primary button-full" type="submit">
          Entrar
        </button>
      </form>

      <p className="auth-footnote">
        Acesso ainda não aprovado? Fale com o Dono ou Gestor da Imobiliária.
      </p>
    </div>
  );
}
