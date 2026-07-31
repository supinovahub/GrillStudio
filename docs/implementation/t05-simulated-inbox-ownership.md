# T05 — Inbound sintético, Inbox e Ownership

## Contrato implementado

- `whatsapp_connections` representa uma origem por Operação e distingue
  `simulator`, `uazapi` e `meta_cloud`. T05 só permite tráfego no conector
  sintético marcado como teste.
- `provider_identities` e `provider_identity_aliases` preservam IDs opacos e
  históricos de alias por conexão. Telefone é opcional; conflito entre alias e
  telefone ou mais de uma identidade/Oportunidade compatível não provoca
  fusão automática e cria revisão privada.
- `messages` é o histórico canônico da Conversa. Inbound, materialização de
  Contato/Oportunidade/Conversa e auditoria são gravados na mesma transação.
- A origem da Conversa é o par imutável `connection_id + provider_chat_id`.
  Existe no máximo uma Conversa aberta por Oportunidade e conexão e uma por
  thread do provedor. Uma Conversa manual de T04 pode receber a origem por CAS
  no primeiro Inbound, preservando seu Ownership humano.

## Ownership, pausa e devolução

`public.conversations` continua sendo a fonte canônica do Ownership:
`pedro` não tem Membro atribuído; `human` exige um Membro ativo. Os comandos
`assume_conversation`, `pause_conversation` e
`return_conversation_to_pedro` autorizam o ator pela Operação, bloqueiam a
linha, exigem `expected_version` e registram antes/depois na auditoria.

Pausa e Ownership são estados separados. Assumir não altera
`automation_mode`; devolver exige a ação explícita `resume_service` e um modo
servido pelo backend. `production` só aparece e só é aceito quando a Operação
está habilitada e sem pausa sistêmica.

Se não houver capacidade, a devolução permanece humana com
`pending_return`, modo, ação, solicitante e versão registrados. Uma mensagem
humana ou troca/desativação do responsável invalida a devolução pendente e
gera auditoria. Nesta fatia, o seam transacional de capacidade aceita menos de
30 Conversas ativas do Pedro; o controle completo pertence a T07.

## Idempotência, transporte e segurança

- Inbound deduplica por `(connection_id, provider_message_id)`.
- Outbound humano deduplica por `(conversation_id, command_id)`. O formulário
  cria um único `command_id` estável e a captura sintética nunca contém
  destinatário nem tenta egress.
- `POST /api/simulator/whatsapp/inbound` existe somente em Preview, valida um
  bearer token sintético com comparação constante, exige JSON e limita o
  corpo real a 64 KiB independentemente de `Content-Length`. Fora de Preview
  responde `404` antes de autenticar ou ler o payload.
- A rota é o único chamador do RPC de ingestão, concedido apenas a
  `service_role`. Browser autenticado recebe somente RPCs estreitos.
- RLS limita Inbox, Conversas, Mensagens e conexões à permissão
  `manage_conversations` da Operação. Tabelas de identidade sem política
  autenticada e tabelas de revisão/captura privadas permanecem fail-closed.
- Eventos de Inbound, assunção, pausa, devolução, devolução pendente,
  invalidação e outbound capturado carregam `trace_id` e `correlation_id` sem
  registrar conteúdo sensível no evento.

## Superfícies

- `/app/atendimentos`: lista as Conversas abertas da Operação com última
  mensagem, origem, etapa, Ownership, modo, pendência e revisão.
- `/app/atendimentos/[id]`: mostra histórico, contexto da Oportunidade,
  conexão e Ownership; oferece apenas as ações autorizadas pelo servidor.
- Lista e detalhe são funcionais em desktop e em viewport móvel de 390 px.

## Matriz de verificação

| Cenário | Evidência |
|---|---|
| Inbound idempotente, origem fixa e materialização canônica | Black-box |
| Assunção versionada, concorrência com um vencedor e gate de produção | Black-box |
| RLS positiva/negativa, cross-Operation e escrita direta recusada | Black-box |
| Alias/telefone ambíguos sem auto-merge | Black-box |
| Retorno de `lost` pelo helper T04 e `purchased` fechado com nova Oportunidade | Black-box |
| Pin manual por CAS preservando responsável humano | Black-box |
| Capacidade cheia, devolução pendente e cancelamento por mensagem humana | Black-box |
| Desativação transfere Ownership e invalida pendência | Black-box |
| Inbox desktop/móvel e rota HTTP sintética real | Black-box |
| Normalização do contrato, autenticação e limite byte a byte da rota | Unitário |

O gate da Preview exige ainda migrations desde zero, `db lint`, tipos gerados
exatos, lint, typecheck, unitários, build e a suíte black-box completa.

## Fronteiras e limitações fail-closed

- **T06:** substituirá o processamento síncrono por webhook inbox/outbox
  duráveis, filas, leases, ordenação, retry, dead letter e reconciliação. T05
  não recebe Uazapi/Meta nem realiza egress real.
- **T07:** substituirá o predicate mínimo `< 30` por horários, estados
  dormindo, reservas, backlog e limiares 10/25/30. Uma devolução sem vaga não
  é executada silenciosamente.
- **T21:** atribuirá Calls, liberará briefing/telefone ao Corretor na janela
  correta e moverá a Oportunidade para `call_scheduled`. T05 não amplia acesso
  de Corretor nem implementa distribuição.

Sem identidade ou Oportunidade inequívoca, permissão, versão atual, conexão
sintética ativa, vaga para devolução ou gate de produção, o sistema revisa,
mantém pendente ou recusa; não presume associação, envio ou Ownership.
