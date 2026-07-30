# Eventos, Filas e Automações v1

## 1. Modelo de execução

O sistema opera com entrega **pelo menos uma vez**. Webhooks, filas e APIs podem repetir eventos. “Exatamente uma vez” não é presumido; o efeito único é obtido com:

- inbox de webhooks;
- chaves de idempotência;
- constraints do banco;
- transações curtas;
- consumidores capazes de repetir com segurança;
- reconciliação periódica.

O evento de domínio é gravado no outbox na mesma transação da alteração. Um dispatcher publica o evento e marca o outbox como concluído.

## 2. Envelope padrão

```json
{
  "event_id": "uuid",
  "event_type": "whatsapp.message.received.v1",
  "occurred_at": "2026-07-30T12:00:00Z",
  "organization_id": "uuid",
  "aggregate": {
    "type": "conversation",
    "id": "uuid",
    "version": 18
  },
  "actor": {
    "type": "provider|user|ai|system",
    "id": "string"
  },
  "correlation_id": "uuid",
  "causation_id": "uuid|null",
  "idempotency_key": "string",
  "payload": {}
}
```

Regras:

- nome no passado: algo que já aconteceu;
- versão no final;
- payload mínimo e sem segredo;
- consumidor desconhecido ignora campos adicionais;
- mudança incompatível cria `v2`;
- conteúdo grande ou sensível é referenciado por ID, não copiado.

## 3. Filas

Usar Supabase Basic Queues por durabilidade. As tabelas das filas permanecem fora da Data API.

| Fila | Responsabilidade | Chave de ordenação |
|---|---|---|
| `inbound-whatsapp` | normalizar/processar eventos recebidos | conexão + conversa |
| `ai-turns` | construir e executar um turno do Pedro | conversa |
| `outbound-whatsapp` | enviar texto/mídia e registrar resultado | conversa |
| `scheduled-actions` | executar jobs vencidos | agregado |
| `call-distribution` | ofertas, expirações e redistribuição | call |
| `campaign-dispatch` | liberar contatos/ondas | campanha |
| `media-processing` | download, validação, transcrição/OCR | anexo |
| `notifications` | app, push e WhatsApp permitido | destinatário |
| `reconciliation` | corrigir divergências e itens órfãos | agregado |
| `dead-letter` | falhas esgotadas | origem |

## 4. Catálogo de eventos

### 4.1 Mensageria

- `whatsapp.webhook.accepted.v1`
- `whatsapp.message.received.v1`
- `whatsapp.message.edited.v1`
- `whatsapp.message.deleted.v1`
- `whatsapp.message.reaction_received.v1`
- `whatsapp.receipt.received.v1`
- `message.persisted.v1`
- `message.send_requested.v1`
- `message.sent.v1`
- `message.delivered.v1`
- `message.read.v1`
- `message.send_failed.v1`
- `message.suppressed.v1`
- `media.processing_requested.v1`
- `media.processed.v1`
- `media.processing_failed.v1`

### 4.2 Conversa e IA

- `conversation.opened.v1`
- `conversation.capacity_reserved.v1`
- `conversation.sleeping.v1`
- `conversation.woken.v1`
- `conversation.owner_changed.v1`
- `conversation.returned_to_ai.v1`
- `conversation.turn_requested.v1`
- `ai.turn.started.v1`
- `ai.turn.completed.v1`
- `ai.turn.rejected_stale_state.v1`
- `ai.response.proposed.v1`
- `ai.response.approved.v1`
- `ai.response.rejected.v1`
- `conversation.escalated.v1`
- `conversation.paused.v1`
- `conversation.resumed.v1`
- `optout.detected.v1`
- `optout.applied.v1`
- `optout.overridden.v1`

### 4.3 Qualificação e conhecimento

- `qualification.value_recorded.v1`
- `qualification.value_conflict_detected.v1`
- `qualification.completed.v1`
- `project.match_computed.v1`
- `project.preview_sent.v1`
- `faq.answer_used.v1`
- `knowledge.answer_missing.v1`
- `learning.suggestion_created.v1`
- `context.version_published.v1`
- `regression.run_completed.v1`

### 4.4 Campanhas e follow-up

- `campaign.import_completed.v1`
- `campaign.consent_confirmed.v1`
- `campaign.review_requested.v1`
- `campaign.approved.v1`
- `campaign.started.v1`
- `campaign.wave_released.v1`
- `campaign.contact_suppressed.v1`
- `campaign.paused.v1`
- `campaign.completed.v1`
- `followup.scheduled.v1`
- `followup.due.v1`
- `followup.cancelled.v1`
- `followup.completed.v1`

### 4.5 Calls

- `call.hold_created.v1`
- `call.distribution_started.v1`
- `call.offer_sent.v1`
- `call.offer_expired.v1`
- `call.offer_accepted.v1`
- `call.offer_lost_race.v1`
- `call.broadcast_started.v1`
- `call.unassigned_alerted.v1`
- `call.assigned.v1`
- `call.rescheduled.v1`
- `call.reminder_due.v1`
- `call.completed.v1`
- `call.no_show.v1`
- `call.result_recorded.v1`
- `call.result_overdue.v1`

### 4.6 Pipeline e operação

- `opportunity.created.v1`
- `opportunity.stage_changed.v1`
- `opportunity.lost.v1`
- `sale.recorded.v1`
- `capacity.threshold_reached.v1`
- `capacity.admission_paused.v1`
- `capacity.admission_resumed.v1`
- `connector.health_degraded.v1`
- `budget.threshold_reached.v1`
- `alert.created.v1`
- `notification.requested.v1`

## 5. Entrada por webhook

O Route Handler deve:

1. limitar tamanho e método;
2. identificar conexão;
3. verificar assinatura/autenticidade;
4. guardar payload bruto;
5. calcular provider event ID e hash;
6. inserir em `webhook_inbox` com constraint única;
7. normalizar os eventos mínimos;
8. persistir mensagem/receipt em transação;
9. criar outbox;
10. responder rapidamente ao provedor.

Erros:

- assinatura inválida: rejeitar e alertar por volume;
- payload desconhecido: aceitar somente se a política do provedor exigir, marcar `unsupported`;
- duplicado: responder sucesso sem novo efeito;
- banco indisponível: retornar erro que permita retry do provedor;
- processamento de IA nunca ocorre dentro do request do webhook.

## 6. Ordenação e lease por conversa

Somente um turno mutável pode operar por conversa.

1. consumidor tenta adquirir lease com expiração curta;
2. lê todas as mensagens ainda não processadas;
3. agrupa mensagens conforme a regra aprovada;
4. atualiza a versão da conversa;
5. conclui e libera lease;
6. se falhar, a expiração permite recuperação.

Mensagens recebidas durante a geração não são perdidas. Ao terminar, se houver inbound novo, agenda-se outro turno. A resposta gerada com `expected_version` antigo não é enviada.

## 7. Agenda durável

`scheduled_jobs` é a fonte de verdade para ações futuras. Supabase Cron chama o despachante em intervalo pequeno; ele:

1. seleciona jobs `pending` e vencidos com `FOR UPDATE SKIP LOCKED`;
2. cria lease;
3. publica na fila apropriada;
4. marca `leased`;
5. consumidor conclui ou devolve para retry.

Categorias:

- atraso humano de resposta;
- retomada após gap de cinco minutos;
- cinco tentativas dentro de 24 horas;
- passos da esteira de seis meses;
- lembretes de call em 1 hora e 10 minutos;
- expiração de oferta individual;
- início de broadcast aos 15 minutos;
- alerta de call sem corretor após uma hora;
- cobrança de resultado da call;
- ondas de campanha;
- validade de conhecimento;
- reconciliação e health checks.

Nenhum processo depende de `setTimeout`, processo residente ou função serverless dormindo.

## 8. Políticas por fluxo

### 8.1 Resposta do Pedro

Antes de enfileirar:

- IA está habilitada no escopo?
- conversa não pertence a humano?
- está dentro do horário de abertura ou já estava em andamento às 23:59?
- não há opt-out?
- mensagem não foi superada por inbound novo?
- não existe ação idêntica?
- conector está saudável?
- resposta passou pelo motor de risco?

Modo:

- `shadow`: persiste sugestão, não envia;
- `assisted`: aguarda aprovação humana;
- `production`: agenda envio automático;
- `human`: IA observa/aprende conforme política, sem enviar.

### 8.2 Gap de cinco minutos

Se Pedro respondeu uma pergunta lateral sem pergunta de qualificação:

- agenda `qualification_resume` para +5 min;
- novo inbound cancela esse job;
- se vencer, recalcula a próxima pergunta;
- não reaproveita texto pré-gerado se o estado mudou.

### 8.3 Opt-out em corrida

Quando chega pedido para não chamar:

1. transação marca supressão;
2. cancela jobs pendentes;
3. mensagens ainda na fila revalidam a supressão antes do envio;
4. cria alerta ao gestor com ações possíveis;
5. Pedro não envia explicação adicional se a regra aprovada mandar silêncio.

### 8.4 Capacidade

Eventos de entrada tentam reservar vaga em função atômica:

- menos de 25: admite até o teto transacional;
- ao chegar a 25: cria/atualiza pausa somente de campanhas, reativações e follow-ups; inbound ainda pode ocupar as vagas restantes;
- em 30: inbound fica em backlog prioritário sem adquirir vaga;
- abaixo de 10 por cinco minutos e sem inbound nos últimos dois minutos: libera as proativas e publica retomada;
- dormindo após cinco minutos sai da contagem ativa;
- resposta do lead exige nova reserva; sem vaga, fica em backlog prioritário.

### 8.5 Call

Jobs:

- expirar oferta preferencial em 30 minutos;
- iniciar distribuição comum;
- avançar destinatário quando cada oferta individual vence em cinco minutos;
- abrir broadcast no minuto 15;
- alertar após uma hora da oferta ampla sem aceite;
- continuar redistribuição até aceite ou intervenção;
- liberar chat e telefone ao corretor 30 minutos antes;
- lembretes ao lead em 1 hora e 10 minutos.

Aceite chama uma função atômica:

```text
accept_call_offer(call_id, offer_id, membership_id, expected_version)
```

Ela valida disponibilidade, elegibilidade e ausência de vencedor; grava assignment, vence demais ofertas e cria outbox. Somente o primeiro commit vence.

### 8.6 Campanha

Antes de cada contato:

- campanha continua ativa;
- consentimento foi confirmado;
- conexão escolhida continua ativa;
- contato não está suprimido;
- não existe conversa humana ativa incompatível;
- capacidade aceita nova conversa;
- janela de envio permite;
- limite da onda não foi excedido.

Campanha é prioridade inferior a inbound, resposta de lead, call e follow-up iniciado.

## 9. Retry, backoff e dead letter

Classificação:

- `retryable`: timeout, 429, 5xx, indisponibilidade transitória;
- `non_retryable`: schema inválido, destinatário inválido, permissão negada;
- `conflict`: estado mudou; recalcular em vez de repetir comando antigo.

Padrão inicial, ajustável por fila:

- backoff exponencial com jitter;
- limite de tentativas;
- `Retry-After` do provedor prevalece;
- após esgotar, mover para dead letter e criar alerta;
- replay manual exige permissão e nova chave de operação.

Para envio WhatsApp, consultar/conciliar status antes de repetir quando houver dúvida se o provedor recebeu a primeira chamada.

## 10. Idempotência

Exemplos de chaves:

```text
webhook:{connection_id}:{provider_event_id}
inbound-message:{connection_id}:{provider_message_id}
ai-turn:{conversation_id}:{last_inbound_message_id}:{context_version}
send:{message_id}
followup:{opportunity_id}:{plan_version}:{step}
call-offer:{call_id}:{round}:{recipient_id}
call-reminder:{call_id}:{offset}
campaign-send:{campaign_id}:{contact_id}:{attempt}
stage-change:{opportunity_id}:{from}:{to}:{command_id}
```

Uma chave representa o mesmo efeito, não apenas a mesma requisição HTTP.

## 11. Reconciliação

Jobs periódicos procuram:

- mensagens `queued/sent` sem atualização além do prazo;
- conversas com lease vencido;
- jobs `leased` abandonados;
- calls futuras sem assignment;
- ofertas pendentes já expiradas;
- campanha `running` sem jobs;
- supressão com mensagem enfileirada;
- contagem de capacidade divergente;
- stage atual diferente do último histórico;
- outbox não publicado;
- webhooks aceitos e não processados;
- media sem processamento;
- versões publicadas sem compilação válida.

Reconciliação corrige quando determinístico; caso contrário alerta o gestor/operador.

## 12. Saúde e circuit breakers

Por conector e provedor:

- taxa de erro;
- latência;
- último webhook;
- autenticação;
- rate limit;
- profundidade da fila.

Ao degradar:

- pausa novos envios daquele conector;
- mantém dados recebidos;
- não troca automaticamente para outro número, pois isso mudaria a identidade da conversa;
- alerta no app/push;
- WhatsApp ao dono/gestor somente nos incidentes definidos, como call agendada sem corretor.

## 13. Retenção

- Payload bruto: retenção curta e configurável.
- Eventos de domínio/auditoria: retenção compatível com operação e obrigações.
- Dead letter: até resolução ou expiração definida.
- Métricas: agregados de longo prazo, conteúdo mínimo.
- Jobs concluídos: arquivamento/particionamento para evitar crescimento indefinido.

## 14. Testes obrigatórios

- webhook repetido 10 vezes produz uma mensagem;
- retry depois de timeout de envio não duplica mensagem;
- duas respostas simultâneas da IA preservam ordem;
- inbound durante atraso cancela/recalcula outbound;
- opt-out concorre com envio e vence;
- dois corretores aceitam a mesma call e só um ganha;
- oferta vencida não pode ser aceita;
- job leased e worker morto volta à fila;
- campanha pausada impede contato já enfileirado;
- capacidade sob 100 requisições concorrentes nunca ultrapassa 30;
- replay de dead letter não repete efeito concluído.

## 15. Referência

- [Supabase Queues Quickstart](https://supabase.com/docs/guides/queues/quickstart)
