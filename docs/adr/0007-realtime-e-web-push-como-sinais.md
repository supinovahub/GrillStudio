---
status: accepted
---

# Realtime e Web Push como sinais sobre alertas persistidos

Alertas são persistidos no Postgres antes de qualquer fan-out; Supabase
Realtime Broadcast privado apenas acelera a interface conectada e Web Push
apenas chama atenção fora da página, sempre com a mesma identidade idempotente
e reconciliação no reload. Todos os alertas normais e críticos permanecem na
plataforma e geram push quando permitido, enquanto WhatsApp para dono/gestor
fica restrito aos riscos imediatos de call aprovados, sem link; aceitamos a
duplicidade controlada entre superfícies porque navegador e sistema
operacional não garantem background, entrega, exibição ou leitura.
