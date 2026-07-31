# T06 — Mensageria durável e idempotente

## Resultado

O inbound sintético e o envio humano agora usam aceitação curta, PGMQ Basic
Queues e consumidores pelo menos uma vez. A chamada HTTP confirma somente
depois de gravar o inbox e publicar a referência na fila na mesma transação.
O domínio e o outbox também são gravados juntos.

Nenhum conector real foi habilitado. O único efeito outbound implementado
continua sendo a captura privada do simulador.

## Contratos

- `private.webhook_inbox` deduplica por conexão + ID do provedor e rejeita o
  mesmo ID com payload divergente.
- Payload e corpo ficam nas tabelas canônicas privadas/públicas. Envelopes,
  tentativas, health e dead letter carregam somente IDs e metadados redigidos.
- `stream_sequence` é atribuído na aceitação. O consumidor não processa N+1
  enquanto N estiver aceito/processando, e a sequência aceita é persistida na
  mensagem inbound.
- `private.outbox_events` recebe a mudança na mesma transação do domínio.
  Publicação PGMQ + estado `published` também ocorre numa só transação.
- Consumidores usam `pgmq.read`, visibility timeout, `set_vt` para retry e
  `archive` somente depois do efeito durável. `pop` não é usado.
- Lease por Conversa exige versão esperada, token e expiração. O lock da
  Conversa e o lease são adquiridos na mesma transação.
- `effect_ledger` fecha o efeito outbound. `outcome_unknown` nunca reenvia:
  exige reconciliação.
- Dead letter mantém a chave do efeito. Replay é explícito, autorizado por
  `manage_conversations`, auditado e idempotente.

## Agenda e wake

- `scheduled_jobs` é a agenda canônica.
- Cron SQL publica vencidos a cada `1 second`.
- Recuperação executa o mesmo worker a cada `5 seconds`.
- Reconciliação de leases/jobs ocorre a cada minuto.
- A rota de ingresso tenta acordar `durable-worker` depois do commit. A Edge
  Function exige JWT; falha no wake não altera o aceite porque o Cron recupera.

## Segurança

- Schemas `private` e `pgmq` não são expostos pela Data API.
- `anon`, `authenticated` e `service_role` não recebem acesso direto a PGMQ.
- O service role acessa somente RPCs públicos allowlisted com implementações
  privadas `SECURITY DEFINER`.
- `scheduled_jobs` tem RLS habilitado e não concede acesso direto ao browser.
- Constraints de estado impedem `published`, `completed` e `replayed` sem os
  artefatos obrigatórios.

## Evidências da Preview

No projeto efêmero do PR:

- 10 webhooks iguais: 1 inbox, 1 mensagem e 1 outbox concluído;
- replay com payload divergente: conflito;
- dois consumidores, mais o recovery Cron, drenaram 100 itens do mesmo stream;
  sequências aceitas únicas de 1 a 100 e nenhum lease vazado;
- grants diretos PGMQ para service role: `USAGE=false`, `pop=false`,
  `send=false`; RPC do worker: `execute=true`;
- combinações inválidas de outbox, scheduled job e dead letter foram rejeitadas
  pelas constraints;
- Cron armazenado como `1 second`, `5 seconds` e `* * * * *`.

Esses probes são funcionais, não benchmark de produção. Latência p95/p99,
backlog de 500 e homologação móvel/externa continuam gates live.

## Fronteiras preservadas

- T07 decide capacidade e automação do Pedro.
- T13/T14 implementam conectores reais e reconciliação de resultados incertos.
- T21 homologa produção. Até lá, conexões reais e Pedro em produção continuam
  desligados.
