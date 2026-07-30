---
status: accepted
---

# Banco como estado canônico da operação

O estado da conversa, da qualificação e da próxima ação vive no banco, e não na memória do modelo. O modelo propõe texto e ações estruturadas, mas o backend valida permissão, regras, versão e estado antes de qualquer efeito; essa separação troca alguma complexidade de orquestração por previsibilidade, auditoria e liberdade para substituir modelos.

