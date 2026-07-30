---
status: accepted
date: 2026-07-30
supersedes: 0006-um-unico-projeto-supabase-pago
---

# Preview Branches Supabase como ambiente de desenvolvimento e CI

## Contexto

O GrillStudio continuará com um único projeto Supabase pago como linha principal. O Dono autorizou o plano Pro, Preview Branches efêmeras por pull request e a cobrança variável correspondente, preferindo não executar um banco Supabase local.

O projeto principal `GrillStudio` começa sem Contatos reais, com destinatários allowlisted e Modo produção desligado. Isso não transforma o projeto principal em ambiente de desenvolvimento: agentes, worktrees, CI e previews precisam permanecer isolados dele.

## Decisão

- Cada pull request de implementação recebe uma Preview Branch Supabase própria, cloud, efêmera e sem cópia dos dados do projeto principal.
- A branch Git e a Preview Branch têm o mesmo ciclo de vida. A Preview Branch é criada assim que o draft PR existe e é removida quando o PR é mergeado ou fechado.
- Desenvolvimento e testes executados a partir de um worktree usam exclusivamente URL, chave pública e credenciais de banco da Preview Branch daquele PR.
- Credenciais de Preview Branch nunca são versionadas, copiadas entre PRs ou reutilizadas no projeto principal.
- CI não recebe credenciais do projeto principal. Testes que exigem Supabase aguardam a Preview Branch ficar saudável e usam somente a branch correspondente ao SHA do PR.
- `supabase/seed.sql` e demais fixtures contêm apenas dados sintéticos, determinísticos e seguros. Nenhum dado do projeto principal é copiado para uma Preview Branch.
- Provedores externos permanecem simulados ou restritos a ativos e destinatários de teste. Uma Preview Branch não autoriza egressos reais.
- Migrations são validadas na Preview Branch. O check oficial do Supabase e os checks do repositório são obrigatórios antes do merge.
- O merge por squash na `main` é automático somente quando bloqueadores estão fechados, a branch está atualizada e todos os checks obrigatórios passam.
- O deploy de migrations para o projeto principal acontece pela integração oficial depois do merge. Mudanças destrutivas, dados sintéticos e seeds não são promovidos.
- O projeto principal continua protegido por allowlist, Modo produção desligado, feature flags e kill switch até os portões correspondentes.
- Depois da entrada de Contatos reais, testes destrutivos continuam proibidos no projeto principal; Preview Branches permanecem sem dados de produção.
- Preview Branches são cobradas por hora e não consomem os créditos mensais de compute. O orquestrador deve limitar concorrência, fechar PRs parados e remover branches rapidamente.

## Consequências

O fluxo elimina a dependência de Docker e Supabase local e permite que agentes paralelos testem migrations, Auth, RLS, Storage, Realtime e Edge Functions em ambientes isolados. Em troca, desenvolvimento e CI dependem da disponibilidade do Supabase cloud e geram custo variável.

O check de Preview Branch torna-se parte do portão de merge. Se a integração não provisionar ou não identificar de forma inequívoca a branch do PR, o trabalho pausa; nunca há fallback silencioso para o projeto principal.
