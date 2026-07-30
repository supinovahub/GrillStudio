# Workflow de Preview Branches e ondas automáticas

## Fronteiras

- `main` corresponde ao projeto Supabase principal `GrillStudio`.
- Cada ticket de implementação usa branch Git, worktree, draft PR e Preview Branch Supabase exclusivos.
- Nenhum agente recebe credenciais do projeto principal.
- Seeds, números, identidades e payloads de teste são sintéticos ou allowlisted.
- Tickets `ready-for-human` e portões live não são executados nem mergeados automaticamente.

## Ciclo de um ticket

1. Confirmar que o ticket está aberto, `ready-for-agent`, sem bloqueadores abertos e não atribuído a outro executor.
2. Criar branch e worktree a partir da `origin/main` mais recente.
3. Atribuir o ticket, publicar a branch e abrir draft PR imediatamente.
4. Aguardar o check da Preview Branch ficar saudável.
5. Resolver as credenciais da Preview Branch correspondente e gravá-las somente no ambiente efêmero do worktree/CI.
6. Executar `/implement <issue-url>`, TDD nos seams aprovados e `/code-review origin/main`.
7. Rodar lint, typecheck, testes, build, migrations, RLS e seams aplicáveis.
8. Publicar no SHA verificado o status `Agent verified`, que representa a execução local contra a Preview Branch; CI nunca recebe credenciais do projeto principal.
9. Enviar commits, atualizar a branch com `main` quando necessário e marcar o PR como pronto.
10. Revalidar ticket, dependências nativas, labels e checks `quality`, `Supabase Preview` e `Agent verified`.
11. Solicitar squash auto-merge. GitHub só conclui após todos os checks obrigatórios.
12. Fechar o ticket pelo PR, apagar branch/worktree e recalcular a fronteira da DAG.

## Falha fechada

O orquestrador pausa o ticket quando:

- a Preview Branch não existe, está ambígua ou não ficou saudável;
- o PR recebeu um gate humano ou perdeu `ready-for-agent`;
- um bloqueador reabriu;
- um check obrigatório falhou;
- existe conflito, mudança concorrente de migration ou divergência com `main`;
- o teste exigiria o projeto principal, credencial real ou destinatário não allowlisted;
- o agente não produziu commit verificável ou a revisão encontrou falha crítica.

Não existe fallback para Supabase local nem para o projeto principal.

## Concorrência e custo

A largura de uma onda é limitada pela DAG, pela capacidade configurada e pelo custo de Preview Branches. Draft PR sem executor, PR bloqueado e worktree órfão devem ser encerrados rapidamente. A Preview Branch é cobrada enquanto existir e não usa os créditos mensais de compute.
