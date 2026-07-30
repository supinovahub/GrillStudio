import { BrandMark } from "@/components/brand-mark";
import { getPreviewEnvironment } from "@/lib/environment";

export default function AuthLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const environment = getPreviewEnvironment();

  return (
    <main className="auth-shell" id="conteudo">
      <section className="auth-intro" aria-labelledby="auth-product-name">
        <div className="brand">
          <BrandMark />
          <span id="auth-product-name">GrillStudio</span>
        </div>
        <div className="auth-intro-copy">
          <p className="eyebrow">Operação comercial, sob controle</p>
          <h1>Do primeiro contato à venda, sem perder o fio.</h1>
          <p>
            Um ambiente único para acompanhar Pedro, a equipe e cada decisão
            comercial com segurança.
          </p>
        </div>
        <div className="preview-seal">
          <span className="status-dot" aria-hidden="true" />
          <span>
            <strong>{environment.label}</strong>
            <small>{environment.branchName}</small>
          </span>
        </div>
      </section>
      <section className="auth-stage">{children}</section>
    </main>
  );
}
