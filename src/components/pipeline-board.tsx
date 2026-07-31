import Link from "next/link";

import { transitionOpportunityAction } from "@/lib/leads/actions";
import {
  pipelineStageLabels,
  pipelineStages,
  type PipelineBoard as PipelineBoardData,
  type PipelineStage,
} from "@/lib/leads/types";

function formatElapsed(date: string): string {
  const elapsed = Math.max(0, Date.now() - new Date(date).getTime());
  const days = Math.floor(elapsed / 86_400_000);
  if (days > 0) {
    return `${days}d nesta etapa`;
  }
  const hours = Math.floor(elapsed / 3_600_000);
  return hours > 0 ? `${hours}h nesta etapa` : "agora";
}

export function PipelineBoard({
  board,
  returnTo,
}: {
  board: PipelineBoardData;
  returnTo: string;
}) {
  return (
    <div className="kanban-board" aria-label="Pipeline comercial">
      {board.stages.map((stage) => {
        const cards = board.cards.filter((card) => card.stage === stage.key);

        return (
          <section
            className="kanban-column"
            key={stage.key}
            aria-labelledby={`kanban-stage-${stage.key}`}
          >
            <header>
              <h2 id={`kanban-stage-${stage.key}`}>{stage.label}</h2>
              <span className="count-badge">{cards.length}</span>
            </header>
            <div className="kanban-cards">
              {cards.length > 0 ? (
                cards.map((card) => (
                  <article className="kanban-card" key={card.id}>
                    <div className="kanban-card-heading">
                      <div>
                        <Link href={`/app/leads/${card.id}`}>
                          {card.display_name || "Nome não informado"}
                        </Link>
                        <span>{card.phone_e164}</span>
                      </div>
                      {card.has_opt_out ? (
                        <span className="lead-opt-out">Opt-out</span>
                      ) : null}
                    </div>
                    <dl className="lead-card-facts">
                      <div>
                        <dt>Origem</dt>
                        <dd>{card.source_type}</dd>
                      </div>
                      <div>
                        <dt>Responsável</dt>
                        <dd>{card.assigned_name || "Sem responsável"}</dd>
                      </div>
                      <div>
                        <dt>Tempo</dt>
                        <dd>{formatElapsed(card.updated_at)}</dd>
                      </div>
                      <div>
                        <dt>Unidades</dt>
                        <dd>
                          {card.unit_count} ·{" "}
                          {card.amount_scope === "total"
                            ? "valor total"
                            : "por unidade"}
                        </dd>
                      </div>
                    </dl>
                    {card.stage !== "purchased" ? (
                      <details className="kanban-transition">
                        <summary>Alterar etapa</summary>
                        <form action={transitionOpportunityAction}>
                          <input
                            name="opportunity_id"
                            type="hidden"
                            value={card.id}
                          />
                          <input
                            name="expected_version"
                            type="hidden"
                            value={card.version}
                          />
                          <input
                            name="return_to"
                            type="hidden"
                            value={returnTo}
                          />
                          <label>
                            Próxima etapa
                            <select
                              name="target_stage"
                              required
                              defaultValue=""
                            >
                              <option disabled value="">
                                Selecione
                              </option>
                              {pipelineStages
                                .filter(
                                  (target) => target.key !== card.stage,
                                )
                                .map((target) => (
                                  <option key={target.key} value={target.key}>
                                    {target.label}
                                  </option>
                                ))}
                            </select>
                          </label>
                          <label>
                            Motivo ou contexto
                            <textarea
                              name="transition_reason"
                              placeholder="Obrigatório ao mover para Perdido"
                              rows={2}
                            />
                          </label>
                          {card.stage === "lost" ? (
                            <label className="check-field">
                              <input name="human_decision" type="checkbox" />
                              <span>
                                Confirmo a decisão humana de reativar este Lead
                              </span>
                            </label>
                          ) : null}
                          <button
                            className="button button-secondary"
                            type="submit"
                          >
                            Confirmar alteração
                          </button>
                        </form>
                      </details>
                    ) : (
                      <p className="kanban-closed">
                        {pipelineStageLabels.purchased} não reabre.
                      </p>
                    )}
                  </article>
                ))
              ) : (
                <p className="kanban-empty">Nenhum Lead nesta etapa.</p>
              )}
            </div>
          </section>
        );
      })}
    </div>
  );
}

export function stageLabel(stage: PipelineStage): string {
  return pipelineStageLabels[stage];
}
