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
  cria Conversa nem envia mensagem.
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

`transition_opportunity` recebe a versão esperada, bloqueia escrita direta da
Etapa, valida a máquina de estados, altera a linha, acrescenta o histórico e
grava auditoria na mesma transação. `Comprado` não possui saída. Conflito
otimista retorna o código de domínio `40001` em HTTP 409 sem acionar retries do
banco.

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
- registra um evento de auditoria redigido.

## Superfícies

- `/app/leads`: cadastro manual e lista autorizada;
- `/app/leads/[id]`: identidade, contexto, Participantes, origens, histórico,
  transição protegida e fusão manual;
- `/app/kanban`: nove colunas fixas da Operação;
- `/app/meu-pipeline`: somente Oportunidades atribuídas e liberadas ao
  Corretor.

As tabelas em `public` têm RLS e grants explícitos. Dono/Gestor veem a Operação;
Corretor vê apenas Oportunidades atribuídas a partir de Call agendada. Todas as
mutações do cliente passam por RPCs estreitas.

## Verificação na Preview

Preview usada durante a implementação: `inokygcjvzhvyvdgxblm`, correspondente
à branch `agent/t04-issue-16` e ao PR 64.

- migration aplicada e `supabase db lint` sem erros;
- tipos gerados a partir da própria Preview;
- lint, typecheck, unitários e build;
- testes black-box de E.164, dedupe, RLS, histórico, transições, fusão,
  Opt-out, reabertura e auditoria;
- regressões de Auth/shell e gestão de Membros.

A Preview deverá ser recriada depois da integração da T03 para provar a
sequência completa de migrations a partir de uma branch efêmera limpa.
