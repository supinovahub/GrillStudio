# T01 — Fundação de acesso e Operação

## Dicionário de dados

| Relação | Finalidade | Escopo de leitura no cliente | Escrita |
| --- | --- | --- | --- |
| `organizations` | Imobiliária e fuso canônico | Membro ativo da organização | Somente fluxo administrativo futuro |
| `operations` | Operação pertencente à Imobiliária | Membro ativo atribuído | Somente fluxo administrativo futuro |
| `memberships` | Papel e estado do usuário | O próprio membro ativo | Somente fluxo administrativo futuro |
| `membership_operations` | Atribuição do membro à Operação | A própria atribuição ativa | Somente fluxo administrativo futuro |
| `operation_settings` | Produção ligada/desligada | Dono/Gestor atribuído | RPC privada de contenção |
| `system_pauses` | Pausa, razão, origem e rastreio | Dono/Gestor atribuído | RPC privada de contenção |
| `audit.audit_events` | Evidência imutável de mutação crítica | Não exposta pela Data API | Funções privadas auditadas |

Todos os registros públicos carregam diretamente o `organization_id` quando
participam do isolamento multi-tenant. As chaves compostas impedem associar
uma entidade de uma Imobiliária a uma Operação de outra.

## Invariantes e índices

- no máximo uma Operação padrão por Imobiliária;
- no máximo um Dono ativo por Imobiliária;
- no máximo uma pausa ativa por Operação;
- índices explícitos para busca de membro, atribuição por Operação e auditoria
  temporal;
- RLS ativa em toda tabela do schema `public`, sem privilégios de escrita para
  `authenticated`;
- funções `security definer` somente no schema `private`, com
  `search_path = ''`.

O black-box da Preview Branch disputa simultaneamente cada índice parcial,
confere os índices no catálogo e testa cada tabela/ator/verbo com payloads
válidos.

## Validação e tipos

`Agent verified` resolve apenas a Preview Branch do PR, roda `supabase db lint`
contra a URL direta efêmera, gera tipos TypeScript a partir dessa mesma base e
executa o black-box. Nenhum desses passos usa o projeto principal ou uma
instância local.

## Plano de forward fix

A migration é aditiva e ainda não recebe dados reais. Se falhar ao ser aplicada
na Preview Branch, a correção é uma nova migration que:

1. preserva os registros sintéticos para diagnóstico;
2. corrige funções, policies ou índices de forma idempotente;
3. repete lint, geração de tipos, testes concorrentes e RLS;
4. só então substitui a Preview Branch descartável.

Não há rollback destrutivo no projeto principal. Antes do lançamento, qualquer
mudança incompatível exige migration de transição e verificação de leitura das
duas versões.
