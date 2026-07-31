# T03 — Perfil institucional e Contexto inicial

## Entrega

O slice publica o Contexto inicial da Operação sem transformar configuração
mutável em memória implícita:

- `institutional_profile_versions` conserva o snapshot factual por campo;
- `personas` identifica a Persona sem semear uma pessoa real;
- `persona_versions` conserva identidade, biografia, estilo, instruções e
  regras críticas protegidas;
- `context_publications` une uma versão factual e uma comportamental em uma
  publicação imutável;
- `operation_settings.active_context_publication_id` é o único ponteiro ativo.

O pacote inicial inclui somente decisões aprovadas de estilo, limites,
qualificação, agendamento e escalonamento. Nome completo, CRECI, experiência,
CNPJ, endereço e demais fatos da primeira Operação começam vazios.

## Estado e concorrência

Versões percorrem `draft → validating → published → archived`. Salvar após a
validação devolve o conteúdo a `draft`. A validação calcula erros, diff e hash.
A publicação:

1. bloqueia `operation_settings` e as duas versões;
2. compara `expected_version`;
3. exige validação sem erros;
4. arquiva as versões anteriormente apontadas;
5. publica snapshots/hashes com autor e data;
6. cria `context_publications`;
7. troca o único ponteiro ativo;
8. grava auditoria na mesma transação.

Triggers impedem alteração ou exclusão de uma versão publicada e tornam a
publicação append-only. Uma tentativa pela RPC suportada é recusada e
auditada sem apagar o evento por rollback.

## Autoridade

- `publish_knowledge` prepara fatos institucionais;
- `train_pedro` prepara biografia e estilo;
- `publish_learning` permite ao Gestor publicar mudanças comportamentais da
  mesma identidade;
- somente o Dono confirma fatos institucionais, cria a primeira identidade,
  muda identidade e prepara o primeiro pacote;
- validação combinada exige `publish_knowledge + train_pedro`;
- publicação combinada exige `publish_knowledge + publish_learning`.

Um Gestor não consegue carregar uma identidade diferente na publicação. Se
alterar valor, fonte, validade ou divulgação de um campo antes confirmado, a
confirmação do Dono é removida.

`publish_knowledge` não expõe Persona; `train_pedro` e `publish_learning` não
expõem fatos institucionais. O histórico combinado só aparece para quem tem
autoridade nos dois domínios.

## Prontidão do Contexto

A leitura consulta somente `active_context_publication_id` e reexecuta a
validação completa sobre os snapshots publicados. Assim, uma fonte ou validade
que expire depois da publicação volta a aparecer como bloqueio. São
obrigatórios:

- nome comercial;
- CRECI PJ e UF;
- nome completo da Persona ativa;
- CRECI e UF quando a Persona se apresenta como Corretor.

Campos opcionais ausentes geram alertas. A interface usa a declaração
**Informado e confirmado pelo dono** e não alega validação externa. T03 não
altera `operation_settings.production_enabled`, não publica RPC para isso e não
oferece ação de produção na interface. Esse estado permanece somente leitura
até o ticket responsável pelos demais gates.

As regras críticas ficam em `protected_rules`, fora dos campos editáveis. Elas
cobrem integridade factual, opt-out, privacidade, pergunta direta sobre IA,
efeitos comerciais proibidos e riscos que exigem escalonamento silencioso. A
validação e a publicação exigem a representação canônica e incluem essas regras
no diff, snapshot e hash.

## Segurança e validação

As quatro tabelas novas em `public` têm `GRANT SELECT` explícito e RLS.
Escritas diretas não são concedidas. As mutações ficam em funções
`security definer` no schema `private`, com wrappers `security invoker`,
`search_path = ''` e `EXECUTE` revogado de `PUBLIC`.

O black-box da Preview Branch cobre:

- baseline sem fatos inventados;
- RLS positiva e negativa, inclusive Gestores com uma única permissão;
- preparação por Gestor e identidade exclusiva do Dono;
- validação, diff, hashes e conflito de versão;
- regras críticas protegidas contra adulteração antes e depois da validação;
- publicação e arquivamento;
- imutabilidade em chamada autenticada e privilegiada;
- auditoria de tentativa recusada;
- ausência de mutator de produção e estado ainda desligado;
- FKs compostas contra referências entre Operações e índices de suporte;
- criação concorrente serializada com resultado estável;
- revalidação da validade no snapshot publicado;
- segunda publicação da mesma identidade por Gestor autorizado;
- superfície funcional na PWA.

O rollback operacional é forward-only: nenhuma versão publicada é editada.
Uma correção cria nova versão/publicação e preserva o histórico.
