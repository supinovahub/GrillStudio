export default function CentralLoading() {
  return (
    <main className="centered-state" id="conteudo">
      <div className="state-panel" aria-busy="true" role="status">
        <span className="loading-line" aria-hidden="true" />
        <p>Carregando a Central da Operação…</p>
      </div>
    </main>
  );
}
