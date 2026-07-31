# T04 — Contatos, Oportunidades e pipeline

## Contrato implementado

- `public.opportunities` foi estendida sem substituir `stage` nem
  `assigned_membership_id`, preservando o contrato usado pela gestão de
  Membros.
- O telefone entra por `private.normalize_phone_e164`: `+1` continua `+1`;
  número brasileiro sem país recebe `+55`; número local sem DDD é rejeitado.
  A unicidade concorrente é `(organization_id, e164)`.
- `contact_phones.original_value` mantém o primeiro valor recebido e
  `contact_phone_observations` preserva todas as grafias posteriores que
  normalizaram para a mesma identidade.
- Contato, Oportunidade e Participante são entidades distintas. Quantidade de
  unidades e escopo de valores pertencem à Oportunidade.
- O cadastro manual executa somente `register`, `assume` ou
  `request_proactive`. A última opção apenas cria um pedido não autorizado; não
  cria Conversa nem envia mensagem. `assume` cria uma única Conversa mínima
  com ownership humano no ator, sem egress; não reutiliza
  `opportunities.assigned_membership_id` como ownership.
- Criação de identidade usa advisory lock transacional por
  `(organization_id, E.164)` antes de consultar ou inserir o Contato.
- `pedro_context` e `private.opportunity_internal_notes` são armazenados e
  consultados por caminhos distintos. A nota interna não está exposta no Data
  API e não aparece no detalhe de Corretor.

## Pipeline canônico

| Token interno | Etapa |
|---|---|
| `new` | Novo |
| `in_service` | Em atendimento |
| `call_scheduled` | Call agendada |
| `negotiation` | Em negociação |
| `proposal_reservation` | Proposta/Reserva |
| `documentation` | Documentação |
| `payment` | Pagamento |
| `purchased` | Comprado |
| `lost` | Perdido |

`transition_opportunity` recebe a versão esperada, autoriza antes do lock,
bloqueia escrita direta da Etapa, altera a linha, acrescenta o histórico
append-only e grava auditoria na mesma transação. Nesta entrega o comando
genérico opera apenas `new → in_service|lost`, `in_service → lost` e a
reativação humana `lost → in_service`. Entrada em `call_scheduled` permanece
fechada até T21; resultados e Etapas humanas pós-Call permanecem fechados até
T24. `Comprado` não possui saída. Conflito otimista retorna o código de domínio
`40001` em HTTP 409 sem acionar retries do banco.

`stage_entered_at` mede o tempo na Etapa e só muda junto com `stage`; alterações
de atribuição e demais metadados não reiniciam esse relógio. A UI recebe
`allowed_actions` do servidor e não oferece movimentos protegidos.

No retorno inbound, `reopen_opportunity_on_inbound` reutiliza a Oportunidade
perdida antes da Call. Depois da Call retorna `human_review_required` sem
alterar a Etapa. Venda retorna `sale_closed`.

## Fusão

`merge_contacts`:

- exige Dono ou Gestor na Operação;
- bloqueia dois Contatos com Conversa `active`;
- mantém todos os telefones e observações de valor original;
- move Oportunidades, Participantes, origens e Conversas;
- consolida Opt-out sem apagar seu histórico;
- mantém o histórico em cada Oportunidade;
- marca o duplicado com `merged_into_contact_id`;
- registra snapshot e mapeamento imutáveis em `contact_merges`;
- exige a versão esperada dos dois Contatos e usa locks em ordem canônica;
- pode ser revertida por `reverse_contact_merge` enquanto os agregados movidos
  não tiverem sofrido alterações posteriores;
- registra eventos de auditoria redigidos para fusão e reversão.

## Superfícies

- `/app/leads`: cadastro manual e lista autorizada;
- `/app/leads/[id]`: identidade, contexto, Participantes, origens, histórico,
  transição protegida e fusão manual;
- `/app/kanban`: nove colunas fixas da Operação;
- `/app/meu-pipeline`: usa `view_scope=my_pipeline` inclusive para usuários
  Gestor+Corretor. Antes de T21, mostra apenas a projeção mínima redigida de
  atribuição coerente e Call dentro da janela de 30 minutos; não libera
  Contato, telefone, Conversa, origem nem metadados.

As tabelas em `public` têm RLS e grants explícitos. Dono/Gestor veem a Operação;
Corretor não recebe o agregado completo antes do predicate de liberação de
T21. Contatos são autorizados pela Operação, não apenas pela Imobiliária.
Observações de telefone e detalhes de origem saem do acesso direto do browser.
Todas as mutações do cliente passam por RPCs estreitas.

## Verificação na Preview

A prova final usa uma nova Preview efêmera do PR 64, recriada depois da
integração de T03. A Preview anterior não é evidência para o hardening desta
revisão. O gate exige migrations completas desde zero, `db lint`, tipos exatos,
lint, typecheck, unitários, build, black-box do domínio e regressões de
Auth/shell e gestão de Membros.
