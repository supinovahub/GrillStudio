# Pacote técnico v1 — Plataforma Studios SP

Este pacote transforma a [Especificação do Produto v1](./Especificacao-do-Produto-v1.md) em um plano implementável. A especificação continua sendo a fonte de verdade sobre comportamento, regras de negócio e escopo. Em caso de divergência, ela prevalece até que uma decisão seja registrada em uma nova versão.

## Documentos

1. [Arquitetura Técnica v1](./Arquitetura-Tecnica-v1.md)  
   Componentes, limites, fluxos críticos, execução da IA, ambientes e decisões de confiabilidade.

2. [Modelo de Dados e Segurança v1](./Modelo-de-Dados-e-Seguranca-v1.md)  
   Entidades, estados, constraints, funções atômicas, RLS, armazenamento e auditoria.

3. [Eventos, Filas e Automações v1](./Eventos-Filas-e-Automacoes-v1.md)  
   Contratos de eventos, filas, agendamentos, idempotência, ordenação, retries e reconciliação.

4. [Mapa de Telas v1](./Mapa-de-Telas-v1.md)  
   Arquitetura de informação, rotas, permissões, estados de interface e direção visual.

5. [Backlog, Testes e Piloto v1](./Backlog-Testes-e-Piloto-v1.md)  
   Sequência de implementação, critérios de aceite técnicos, estratégia de qualidade e entrada controlada em produção.

## Decisões estruturantes

- Aplicação web em Next.js 16 com App Router e TypeScript.
- Supabase gerenciado para Postgres, Auth, RLS, Storage, Realtime, Queues e Cron.
- Uazapi e Meta Cloud API atrás de uma camada única de conectores de WhatsApp.
- OpenAI Responses API com ferramentas tipadas; o modelo propõe ações e o backend valida e executa.
- Banco de dados como estado canônico. Nenhuma regra operacional depende da “memória” do modelo.
- Processamento assíncrono com entrega pelo menos uma vez e consumidores idempotentes.
- `scheduled_jobs` como agenda durável de lembretes, follow-ups, campanhas e prazos; sem timers em memória.
- Separação física entre staging e produção.
- Toda tabela exposta tem RLS; segredos ficam fora do schema exposto e nunca chegam ao navegador.

## Portões antes de produção

O MVP só entra em produção depois que:

- isolamento entre imobiliárias for provado por testes automatizados de RLS;
- duplicidade de webhook, envio e aceite de call estiver coberta por idempotência;
- opt-out interromper mensagens mesmo quando competir com um envio já enfileirado;
- a extração e a próxima ação atingirem pelo menos 90% no conjunto de avaliação aprovado;
- staging usar números permitidos e não conseguir atingir leads reais por engano;
- o caminho de consumo das filas cumprir a latência esperada no plano Supabase escolhido;
- alertas, reconciliação e recuperação de falhas tiverem sido exercitados;
- o dono habilitar explicitamente a IA em produção ou em uma campanha específica.

## Status

Este pacote está pronto para orientar modelagem detalhada, criação do repositório e implementação. Não houve alteração em infraestrutura, banco, WhatsApp ou produção nesta etapa.
