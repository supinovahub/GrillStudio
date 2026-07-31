import { describe, expect, it } from "vitest";

import {
  isPipelineStage,
  pipelineStageLabels,
  pipelineStages,
} from "../../src/lib/leads/types";

describe("fixed pipeline", () => {
  it("keeps the nine approved stages in order", () => {
    expect(pipelineStages).toEqual([
      { key: "new", label: "Novo" },
      { key: "in_service", label: "Em atendimento" },
      { key: "call_scheduled", label: "Call agendada" },
      { key: "negotiation", label: "Em negociação" },
      { key: "proposal_reservation", label: "Proposta/Reserva" },
      { key: "documentation", label: "Documentação" },
      { key: "payment", label: "Pagamento" },
      { key: "purchased", label: "Comprado" },
      { key: "lost", label: "Perdido" },
    ]);
    expect(pipelineStageLabels.purchased).toBe("Comprado");
  });

  it("rejects labels and obsolete names as internal stage tokens", () => {
    expect(isPipelineStage("Venda concluída")).toBe(false);
    expect(isPipelineStage("Novo lead")).toBe(false);
    expect(isPipelineStage("Proposta feita")).toBe(false);
    expect(isPipelineStage("purchased")).toBe(true);
  });
});
