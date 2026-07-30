# Modelo de Dados e Segurança v1

## 1. Convenções

- UUIDv7 ou UUID gerado pelo banco para chaves primárias.
- Todas as datas completas em `timestamptz`, sempre UTC; apresentação em `America/Sao_Paulo`.
- Mês/ano da venda em `date` normalizado para o primeiro dia do mês, sem expor dia na interface.
- Toda entidade de negócio multi-tenant contém `organization_id`; agregados operacionais também contêm `operation_id`.
- Tabelas mutáveis relevantes contêm `created_at`, `updated_at` e `version`.
- Exclusão lógica somente onde há justificativa operacional; auditoria nunca é apagada pelo usuário.
- Status são enums do banco ou domínios validados, não texto livre.
- Telefones são normalizados em E.164 e preservam o valor original separadamente.
- Valores monetários usam `numeric`, com moeda explícita.
- JSONB é reservado a payloads externos, snapshots e campos realmente variáveis; relações centrais são colunas/tabelas.

## 2. Schemas

| Schema | Finalidade | Exposto pela Data API |
|---|---|---|
| `public` | Dados acessados pela aplicação com RLS | Sim |
| `private` | segredos, payloads brutos, funções internas e configurações sistêmicas | Não |
| `audit` | trilha imutável de ações e decisões | Não |
| `storage` | metadados do Supabase Storage | conforme políticas |
| `pgmq` | filas do Supabase Queues | Não por padrão |

Views expostas devem usar `security_invoker = true`. Funções `security definer` ficam em schema privado, usam `search_path` fixo, validam organização e têm execução concedida apenas aos papéis necessários.

## 3. Identidade, organizações e acesso

### `organizations`

- `id`
- `name`
- `slug`
- `timezone` default `America/Sao_Paulo`
- `status`: `active | suspended | closed`
- `created_at`

### `operations`

- `id`, `organization_id`
- nome;
- timezone;
- status;
- operação padrão.

O MVP cria uma operação principal por imobiliária, mas capacidade, números, campanhas, agenda, leads e alertas já são particionados por `operation_id`. Isso evita confundir o tenant comercial com a unidade operacional.

### `organization_settings`

- `organization_id` PK/FK
- preferências institucionais;
- marca/configuração global;
- política de suporte;
- orçamento consolidado.

### `operation_settings`

- `operation_id` PK/FK
- horário de abertura e fechamento;
- limites de 10/25/30;
- políticas de atraso;
- flags de IA normal e por canal;
- `active_persona_version_id`
- `active_rule_version_id`
- parâmetros de alertas.

### `memberships`

- `id`, `organization_id`, `user_id`
- `role`: `owner | manager | broker`
- `status`: `pending | active | suspended | revoked`
- flags adicionais: `can_receive_calls`, `is_preferred_receiver`
- unique `(organization_id, user_id)`

Permissões derivam da membership e de tabelas de permissão. Nunca usar `user_metadata` para autorização. Se claims forem usados para acelerar leituras, precisam ser derivados de dados controlados pelo servidor e a política continua validando estado no banco.

### `membership_operations`

Define a quais operações uma membership tem acesso. No MVP, dono e gestor podem receber todas por padrão; corretor só entra nas operações para as quais foi aprovado.

### `staff_profiles`

- `membership_id`
- nome, avatar, telefone/WhatsApp;
- CRECI e dados profissionais configurados;
- preferências de notificação;
- capacidade de receber calls.

Adicionar o WhatsApp não envia código de confirmação no MVP. O risco foi aceito, mas alteração do número é auditada e apenas números formatados/ativos entram na distribuição.

### `invitation_links` e `invitations`

Suportam:

- convite individual;
- link geral;
- cadastro pendente;
- aprovação e definição de papel por dono/gestor.

Até aprovação, o usuário não vê dados da organização.

## 4. Persona, regras e aprendizado

### `personas`

- `id`, `organization_id`
- nome interno e nome apresentado;
- status;
- dados da persona, incluindo CRECI quando configurado.

### `persona_versions`

- `persona_id`, `version_number`
- `instructions`
- `style_rules`
- `biography`
- `status`: `draft | validating | published | archived`
- `published_by`, `published_at`
- `content_hash`

Versões publicadas são imutáveis.

### `rule_sets` e `rule_versions`

Armazenam políticas globais, limites de assunto, escalonamentos, mensagens críticas e regras de campanha. Cada publicação gera snapshot e diff.

### `qualification_definitions`

- título, contexto, ordem;
- tipo de resposta;
- obrigatoriedade;
- aplicabilidade;
- opções e validações;
- validade;
- ativo/inativo.

### `qualification_versions`

Snapshot compilado das perguntas no momento da publicação. Permite reproduzir por que Pedro perguntou ou interpretou algo.

### `faq_entries` e `faq_versions`

- escopo: `global | project`
- pergunta canônica;
- variações;
- resposta-base;
- campos dinâmicos permitidos;
- fonte;
- validade opcional;
- status de aprovação.

### `learning_suggestions`

- origem: mensagem marcada, escalonamento ou padrão detectado;
- resposta observada;
- sugestão;
- evidências;
- status: `new | reviewing | approved | rejected | conflict`;
- conflito com versões existentes.

Aprovar aprendizado não edita instrução em uso. Cria rascunho, roda regressões e exige publicação. Em conflito, o dono/gestor resolve e exclui ou arquiva a regra derrotada.

### `regression_cases`

- entrada simulada;
- estado inicial;
- resposta esperada ou rubrica;
- ações permitidas/proibidas;
- severidade;
- origem;
- ativo.

### `model_profiles`

- provedor e identificador do modelo;
- endpoint e modelo solicitado;
- parâmetros permitidos e seus valores efetivos;
- versão do template/contrato de instructions, schema e toolset;
- hashes canônicos do perfil e do schema;
- compatibilidade com ferramentas/schema;
- status:
  `documented | contract_passed | synthetic_passed | shadow_or_assisted | production_approved | quarantined | deprecated`;
- ambientes permitidos e data/autor da aprovação;
- preço observado, fonte e data de revisão;
- orçamento.

Chaves de API ficam em `private.integration_secrets`, nunca nesta tabela.
O perfil é global e imutável; acesso por credencial e escolha operacional não
fazem parte de seu hash.

### `operation_model_assignments`

- organização e operação;
- conexão BYOK/segredo referenciada, nunca o segredo;
- perfil primário aprovado;
- perfil de fallback aprovado e opcional;
- status, modelo retornado, data e erro redigido do probe da credencial para
  cada perfil;
- versão, data, autor e motivo da ativação;
- configuração anterior para rollback auditável.

Sem fallback configurado, a operação continua válida, mas pausa a conversa
quando o primário esgota retries seguros. Trocar conexão, primário ou fallback
cria nova versão da atribuição e exige confirmação do dono.

### `experiments`, `experiment_variants`, `experiment_assignments`

Experimentos A/B vinculam uma oportunidade a uma única variante pelo período definido. A atribuição é estável e auditável.

### `contact_persona_bindings`

Vincula uma identidade humana ao contato e ao número/conexão quando o experimento usa personas diferentes. Impede troca silenciosa em oportunidades futuras e exige ação humana auditada para alteração.

## 5. Contatos, oportunidades e origem

### `contacts`

- `id`, `organization_id`
- nome conhecido;
- status;
- preferências;
- `merged_into_contact_id` quando fundido;
- timestamps.

### `contact_phones`

- `contact_id`
- `e164`
- valor original;
- `is_primary`
- `verified_at` opcional;
- unique `(organization_id, e164)` para contatos ativos, com processo explícito de fusão.

### `opportunities`

- `id`, `organization_id`, `contact_id`
- `pipeline_stage_id`
- `status`
- `persona_version_id`
- `source_type`
- `assigned_broker_membership_id` opcional;
- `current_conversation_id`
- `last_activity_at`
- `stage_entered_at`
- `version`

Contato e oportunidade são separados. O mesmo telefone pode retornar no futuro sem destruir o histórico anterior. A regra de reabrir ou criar nova oportunidade é explícita e registrada.

### `opportunity_participants`

Co-compradores e participantes, com papel, nome, telefone opcional e consentimento/contexto.

### `form_submissions`

- IDs da Meta;
- respostas cruas e normalizadas;
- campanha/anúncio quando disponível;
- data de consentimento;
- vínculo posterior à oportunidade.

### `source_attributions`

Armazena primeiro toque, último toque e eventos intermediários sem sobrescrever origem.

### `qualification_values`

- `opportunity_id`, `definition_id`
- valor tipado;
- texto original;
- confiança;
- status: `known | inferred | conflicting | stale | not_applicable`
- `valid_until`
- mensagem de evidência;
- unique por oportunidade/definição vigente.

### `qualification_value_history`

Histórico append-only de alterações, autor, mensagem de origem e versão do modelo.

### `opportunity_scores`

Componentes explicáveis do score; não substitui os critérios obrigatórios nem decide sozinho.

## 6. Conversas e mensagens

### `whatsapp_connections`

- `organization_id`
- provider: `uazapi | meta_cloud`
- número e nome;
- status;
- capacidades;
- referência ao segredo;
- health e última sincronização;
- habilitado para inbound/campanha.

### `conversations`

- `opportunity_id`, `connection_id`
- provider conversation/thread ID;
- status;
- `owner_type`: `ai | manager | broker | none`
- `owner_membership_id`
- modo: `shadow | assisted | production | human`
- `ai_enabled_scope`
- `active_turn_lease_until`
- `last_inbound_at`, `last_outbound_at`
- `sleeping_since`
- `version`

Constraint: no máximo uma conversa operacional ativa por oportunidade e conexão, salvo exceção documentada.

### `conversation_access_grants`

Libera o chat e o telefone ao corretor atribuído 30 minutos antes da call. Campos:

- conversa e membership;
- motivo;
- `valid_from`, `valid_until`;
- criado/revogado por.

### `messages`

- conversa, direção, tipo;
- texto;
- status: `received | proposed | approved | queued | sent | delivered | read | failed | suppressed`
- ID e timestamp do provedor;
- `reply_to_message_id`
- `idempotency_key`
- versão de persona, regras e modelo;
- uso e latência;
- `created_by_type`
- conteúdo original editado/excluído quando o provedor informar.

Unique por conexão + ID de mensagem do provedor.

### `ai_executions`

- conversa e mensagens de entrada/saída;
- modelo solicitado e modelo realmente usado;
- perfil e hashes efetivamente usados;
- número da tentativa, retry/fallback e causa;
- versões comportamental e factual;
- hash da instrução compilada e do contexto efetivo;
- ferramentas propostas, aceitas e rejeitadas;
- fase do turno, `expected_version`, `call_id` e chave de idempotência;
- efeito externo: `none | started | recorded | unknown`;
- latência, tokens e custo;
- resultado/erro e trace.

Payload de raciocínio privado do modelo não é armazenado nem exposto.

### `attachments`

- mensagem;
- bucket/path privado;
- MIME, tamanho, hash;
- estado de processamento;
- transcrição/OCR quando permitido;
- metadados sem URL pública permanente.

### `conversation_summaries`

- intervalo coberto;
- resumo factual;
- fatos pendentes;
- hash das mensagens;
- modelo e versão;
- criado em.

O resumo ajuda contexto, mas nunca substitui mensagens/evidências para decisões críticas.

### `opt_outs` e `suppression_entries`

- organização + telefone/contato;
- escopo e motivo;
- mensagem de evidência;
- status;
- decisão posterior do gestor;
- quem reverteu e justificativa.

Aplicar opt-out bloqueia campanhas e mensagens automáticas e cancela jobs pendentes na mesma transação. Qualquer retomada exige ação explícita e auditada do gestor conforme as quatro opções aprovadas.

## 7. Campanhas e follow-ups

### `campaigns`

- organização, nome, tipo;
- conexão escolhida;
- persona/versão;
- modo da IA;
- status: `draft | importing | review | approved | running | paused | completed | cancelled | failed`
- declaração de consentimento;
- limites e janela;
- criado/aprovado por.

### `consent_declarations`

Registra quem confirmou, texto exibido, versão, data, origem da base e campanha. Não substitui opt-out nem torna o contato irrestrito.

### `campaign_imports` e `campaign_import_rows`

Guardam arquivo privado, mapeamento, erros por linha, duplicidades, resultado e vínculo criado. As linhas temporárias de importação não viram lead até passarem pelas regras.

### `campaign_contacts`

- campanha e contato/oportunidade;
- status;
- prioridade;
- variante;
- próximo envio;
- tentativas;
- motivo de supressão.

Unique evita que o mesmo contato seja inserido duas vezes na mesma campanha.

### `campaign_waves`

Controla liberações pequenas, aprovação, volume, resultado e pausa.

### `followup_plans` e `followup_steps`

Plano de até 20 tentativas em seis meses, com passos versionados. O primeiro ciclo de conversa inclui até cinco tentativas dentro de 24 horas; depois migra para esteira longa.

### `scheduled_jobs`

Agenda canônica:

- `id`, `organization_id`
- `job_type`
- `aggregate_type`, `aggregate_id`
- `run_at`
- `status`: `pending | leased | completed | cancelled | dead`
- `attempts`, `max_attempts`
- `lease_until`
- `dedupe_key`
- `payload`
- `last_error`

Unique parcial em `dedupe_key` para jobs ativos. Follow-ups, lembretes, retomadas após gap, deadlines de oferta e ondas dependem desta tabela.

## 8. Empreendimentos

### `projects`

Cadastro resumido:

- nome;
- região/bairro;
- status e disponibilidade;
- faixas de preço, entrada e parcela quando disponíveis;
- objetivo predominante;
- planta/pronto;
- resumo;
- rentabilidade média de locação e valorização, separadas;
- indicação de gestão short stay;
- fonte e validade;
- capa;
- ativo.

### `project_facts`

Fatos tipados com fonte, vigência, unidade e nível de confiança. Evita duplicar o mesmo número em texto livre.

### `project_media`

- tipo: capa, imagem, PDF;
- storage path;
- ordem;
- ativo;
- até cinco imagens por envio é regra do comando, não limite da tabela.

### `project_faqs`

Relaciona FAQ e empreendimento, com override controlado.

### `project_matches`

Registra quais empreendimentos foram avaliados, critérios usados, resultado e por que foram enviados ou descartados. Preço total e entrada são os critérios mínimos de compatibilidade aprovados.

### `project_snapshots`

Congela os dados vistos na curadoria para auditoria. O corretor usa outro portal para detalhes; esta base existe apenas para respostas curtas e prévia.

## 9. Agenda, calls e distribuição

### `availability_rules`

Regras semanais por corretor/gestor, timezone, vigência e capacidade.

### `availability_exceptions`

Bloqueios e disponibilidades pontuais.

### `call_holds`

- oportunidade;
- início e fim;
- formato preferido;
- status;
- expiração;
- criado por.

Slots são de 20 minutos de call + 10 minutos de intervalo.

### `calls`

- hold e oportunidade;
- horário;
- status;
- formato: `video | phone | unknown`;
- corretor atribuído;
- link de vídeo quando existir;
- resultado;
- finalizado por/em;
- `version`.

### `call_offers`

- call, recipient membership;
- rodada;
- tipo: `preferred | sequential | broadcast`
- enviada/em;
- expira/em;
- status: `pending | accepted | declined | expired | lost_race`
- resposta do provedor.

### `call_assignments`

Histórico de atribuição e revogação. A call mantém no máximo uma atribuição ativa por índice único parcial.

### `call_results`

- resultado: `start_negotiation | lost | no_show | no_result`
- motivo/contexto;
- próxima ação;
- autor e data.

`no_result` e `start_negotiation` alertam o gestor e ficam acessíveis a ele.

## 10. Pipeline e venda

### `pipeline_stages`

Seeds fixos do MVP:

1. Novo lead
2. Em atendimento
3. Call agendada
4. Em negociação
5. Proposta feita
6. Documentação
7. Pagamento
8. Comprado
9. Perdido

### `opportunity_stage_history`

Append-only, com etapa anterior/nova, ator, motivo, call relacionada e versão.

### `loss_reasons`

Catálogo configurável com código estável.

### `next_actions`

Responsável, prazo, descrição, status e lembretes.

### `checklist_templates`, `checklist_items`, `opportunity_checklists`

Checklists pós-call configuráveis para proposta, documentação, pagamento e outras etapas.

### `sales`

- oportunidade;
- projeto/unidade em texto quando necessário;
- valor;
- mês/ano;
- responsável;
- status;
- criado/confirmado por.

## 11. Operação, eventos e auditoria

### `alerts` e `notifications`

Alertas persistentes no app/push e, somente nos casos aprovados, WhatsApp ao gestor/dono. O link não é incluído na mensagem de WhatsApp.

### `integration_health_checks`

Série de saúde para Uazapi, Meta, OpenAI, Storage, filas e push, com latência, status e erro redigido.

### `system_pauses`

Pausas globais, por organização, conexão, campanha ou conversa; motivo e origem automática/manual.

### `capacity_snapshots`

Série histórica para métricas. Não é fonte para decisões transacionais.

### `private.webhook_inbox`

Payload bruto, assinatura validada, provider event ID, status e erro. Unique por provedor/conexão/evento.

### `private.outbox_events`

Evento a publicar, agregado, payload, tentativas e status. Criado na transação do domínio.

### `private.idempotency_keys`

Escopo, chave, hash da requisição, resposta e expiração.

### `audit.audit_events`

Append-only:

- ator humano/sistema/modelo;
- organização;
- ação;
- alvo;
- before/after redigidos;
- IP/user agent quando aplicável;
- correlation/trace IDs;
- versão de regras/modelo;
- timestamp.

### `usage_ledger` e `budget_alerts`

Tokens, custo estimado, modelo, organização, campanha, conversa e alerta de orçamento.

## 12. Matriz de acesso

| Recurso | Dono | Gestor | Corretor |
|---|---|---|---|
| Configurações gerais e billing | total | conforme permissão, sem billing sensível | nenhum |
| Pessoas e papéis | total | convidar/aprovar conforme regra | próprio perfil |
| Personas/modelos/publicação | total | operar/testar conforme permissão | nenhum |
| Todos os leads da organização | total | total operacional | somente atribuídos/liberados |
| Conversa antes da call | total | total | sem acesso |
| Conversa 30 min antes da call | total | total | atribuída e liberada |
| Campanhas | total | criar/operar | nenhum |
| Empreendimentos/FAQs | total | operar | leitura necessária à call, se liberada |
| Relatórios | total | operacional | próprios resultados |
| Auditoria | total | operacional conforme permissão | própria atividade |

Administrador da plataforma não recebe acesso automático ao conteúdo das imobiliárias. Suporte excepcional exige concessão temporária, motivo e auditoria.

## 13. Padrão de RLS

Toda policy usa membership ativa da organização e, quando aplicável, acesso à operação. Exemplo conceitual:

```sql
using (
  exists (
    select 1
    from public.memberships m
    where m.organization_id = opportunities.organization_id
      and m.user_id = auth.uid()
      and m.status = 'active'
      and exists (
        select 1
        from public.membership_operations mo
        where mo.membership_id = m.id
          and mo.operation_id = opportunities.operation_id
      )
      and (
        m.role in ('owner', 'manager')
        or (
          m.role = 'broker'
          and opportunities.assigned_broker_membership_id = m.id
        )
      )
  )
)
```

Para `UPDATE`, criar policy de `SELECT` e usar `USING` mais `WITH CHECK`. O cliente não pode alterar `organization_id`, autoria, IDs externos, versões publicadas ou campos sistêmicos. Mutações sensíveis passam por funções/transações do servidor.

## 14. Constraints críticas

- uma membership por usuário/organização;
- um telefone ativo por contato/organização, com fusão explícita;
- uma mensagem por provider message ID/conexão;
- uma execução ativa por `idempotency_key`;
- uma atribuição ativa por call;
- um vencedor por oferta/call;
- um valor vigente por pergunta/oportunidade;
- um assignment A/B vigente por oportunidade/experimento;
- um job ativo por `dedupe_key`;
- uma venda ativa por oportunidade, salvo regra futura;
- etapas só mudam pela função autorizada;
- versão publicada é imutável.

## 15. Privacidade e armazenamento

- Buckets privados: `project-media`, `message-attachments`, `campaign-imports`, `avatars`, `exports`.
- Acesso por policy e URL assinada curta.
- Malware/type/size validation antes de processar anexos.
- Logs não guardam conteúdo integral por padrão.
- CPF, documento e informação sensível recebidos por engano são marcados, ocultados da IA e escalados conforme a especificação.
- Exportação e exclusão seguem política da organização e obrigações legais; a trilha de auditoria preserva somente o necessário.
- Backups e PITR devem ser habilitados e testados conforme o plano escolhido antes da produção.

## 16. Migrações e validação

Cada mudança de banco inclui:

- migration versionada;
- rollback ou plano de forward fix;
- seed de enums/etapas;
- teste positivo e negativo de RLS;
- teste de invariantes concorrentes;
- verificação de índices;
- advisors de segurança e performance;
- atualização do dicionário de dados.

Nenhuma tabela nova em schema exposto é aceita sem RLS habilitada e políticas testadas.

## 17. Referências

- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase Securing your API](https://supabase.com/docs/guides/api/securing-your-api)
- [Supabase Storage Access Control](https://supabase.com/docs/guides/storage/security/access-control)
- [Supabase Server-Side Auth for Next.js](https://supabase.com/docs/guides/auth/server-side/advanced-guide)
