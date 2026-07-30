---
status: accepted
---

# Processamento assíncrono durável e idempotente

Mensagens, campanhas, follow-ups, lembretes e distribuição de calls usam entrega pelo menos uma vez, inbox/outbox, consumidores idempotentes e agendamentos persistidos. A alternativa de timers em memória ou funções aguardando seria mais simples, mas perderia trabalho em reinícios e não suportaria com segurança webhooks repetidos ou falhas parciais.

