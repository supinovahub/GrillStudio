# Evidência de capacidade e compatibilidade dos modelos OpenAI para Pedro

Status: pesquisa técnica para o protótipo do ticket
[#6](https://github.com/supinovahub/GrillStudio/issues/6), sem chamada à API,
credencial, aprovação de modelo ou alteração de produção.

Data da pesquisa: 2026-07-30.

## 1. Resultado executivo

Os três modelos recomendados atualmente pela OpenAI — `gpt-5.6-sol`,
`gpt-5.6-terra` e `gpt-5.6-luna` — documentam os primitivos de API de que o
Pedro precisa: Responses API, Structured Outputs, function calling, streaming,
entrada de texto/imagem e saída de texto. Todos têm janela de contexto de
1.050.000 tokens, entrada máxima de 922.000 e saída máxima de 128.000. Fontes:
[catálogo atual de modelos][models],
[Sol][sol], [Terra][terra] e [Luna][luna].

Isso prova **capacidade de plataforma**, não compatibilidade concreta nem
qualidade de produto. Ainda não é possível aprovar nenhum modelo para produção,
porque:

- os schemas JSON definitivos das ferramentas do Pedro não estão publicados no
  repositório; só existem seus nomes e regras;
- não houve execução do conjunto de regressão;
- a documentação afirma capacidade multilíngue genérica, mas não promete
  qualidade, naturalidade ou domínio imobiliário em português brasileiro;
- não há SLO de latência definido pelo produto nem medição com o contexto real;
- cumprimento de schema não prova que o valor extraído, a ferramenta escolhida
  ou a mensagem sejam semanticamente corretos.

A matriz inicial de avaliação deve preservar a decisão de produto existente:

1. `gpt-5.6-sol` como candidato primário de referência, pois a seção 36.3 da
   Especificação do Produto já o prevê como modelo inicial;
2. `gpt-5.6-terra` como candidato a fallback e desafiante de custo/latência que
   só poderá substituir Sol como primário se os gates empíricos demonstrarem
   equivalência;
3. `gpt-5.6-luna` como candidato para classificação e tarefas auxiliares de
   volume/custo, sem promoção automática ao atendimento.

Essa ordem é uma **hipótese de teste**, não uma aprovação. A OpenAI descreve Sol
como o modelo de fronteira, Terra como equilíbrio entre inteligência e custo e
Luna como opção para volume sensível a custo; também recomenda comparar
configurações em tarefas representativas, pois o melhor esforço depende do
workload. Fontes: [catálogo de modelos][models] e
[guia do GPT-5.6][latest-model].

Fallback automático fica restrito à fronteira **antes de qualquer efeito de
domínio ou envio**. Depois de retries limitados, timeout, conexão interrompida,
rate limit temporário e erro 5xx podem usar o secundário previamente aprovado.
Erro de schema, segurança, política, autenticação, permissão, cota, recusa,
resposta incompleta ou resultado ambíguo depois de um efeito deve pausar ou
reconciliar, não tentar outro modelo às cegas. Essa decisão combina a
[classificação de retry do produto](../product/Eventos-Filas-e-Automacoes-v1.md)
com os [erros da API OpenAI][errors] e o
[backoff recomendado pela OpenAI][rate-limits].

## 2. Contrato imposto pelo GrillStudio

Esta pesquisa aplica as decisões já aceitas no repositório:

- o banco é o estado canônico; o modelo propõe texto e ações, e o backend
  valida permissão, regras, versão e estado antes de qualquer efeito
  ([ADR 0001](../adr/0001-banco-como-estado-canonico.md));
- a entrega é pelo menos uma vez, com inbox/outbox, consumidores idempotentes e
  agendamento durável
  ([ADR 0003](../adr/0003-processamento-assincrono-duravel.md));
- persona e roteiro ficam estáveis na conversa, fatos críticos podem mudar na
  resposta seguinte e cada resposta registra as versões efetivamente usadas
  ([ADR 0005](../adr/0005-contexto-versionado-e-identidade-estavel.md));
- a arquitetura exige resposta estruturada, validação de schema, validação de
  política/estado, execução no backend e `expected_version` em cada ferramenta
  ([Arquitetura Técnica v1](../product/Arquitetura-Tecnica-v1.md));
- `model_profiles` guarda provedor, identificador, parâmetros,
  compatibilidade, status e orçamento, enquanto `ai_executions` registra
  modelo solicitado e efetivo, fallback, versões, ferramentas, latência,
  tokens, custo e erro
  ([Modelo de Dados e Segurança v1](../product/Modelo-de-Dados-e-Seguranca-v1.md));
- modelo novo começa no simulador, só aparece em produção depois de
  compatibilidade e regressão, e a troca em produção exige confirmação do dono
  ([Especificação do Produto v1](../product/Especificacao-do-Produto-v1.md),
  seções 30.3, 30.5 e 36.3).

Consequência: a unidade promovida não é apenas o ID do modelo. É um perfil
imutável:

```text
provider
requested_model
reasoning_effort
reasoning_context
service_tier
instructions_version
behavioral_version
factual_version
toolset_version
schema_hash
parallel_tool_calls
max_output_tokens
store
```

Qualquer alteração material nesse perfil exige repetir ao menos compatibilidade
técnica, suíte crítica e regressão relacionada. Troca de modelo exige a
regressão completa já prevista pelo produto.

## 3. Candidatos atuais

| Modelo | Papel documentado | Contexto / saída máxima | Preço Standard por 1M tokens, contexto curto (entrada / cache / saída) | Preço Standard por 1M tokens, contexto longo (entrada / cache / saída) |
|---|---|---:|---:|---:|
| `gpt-5.6-sol` | Fronteira para trabalho profissional complexo | 1.050.000 / 128.000 | US$ 5,00 / 0,50 / 30,00 | US$ 10,00 / 1,00 / 45,00 |
| `gpt-5.6-terra` | Equilíbrio entre inteligência e custo | 1.050.000 / 128.000 | US$ 2,00 / 0,20 / 12,00 | US$ 4,00 / 0,40 / 18,00 |
| `gpt-5.6-luna` | Volume alto sensível a custo | 1.050.000 / 128.000 | US$ 0,20 / 0,02 / 1,20 | US$ 0,40 / 0,04 / 1,80 |

Os valores são a tabela pública observada na data desta pesquisa e podem mudar.
Nos três modelos, uma requisição com mais de 272 mil tokens de entrada usa a
faixa longa para toda a requisição; cache writes custam 1,25 vez a entrada sem
cache. A Responses API não tem tarifa separada: tokens são cobrados pelo modelo.
Fontes: [preços][pricing], [Sol][sol], [Terra][terra] e [Luna][luna].

Preço publicado não substitui custo medido. O gate deve calcular custo por
turno e conversa com o contexto compilado, ferramentas, reasoning tokens,
cache, retries e fallback reais. Batch e Flex não são candidatos ao caminho
síncrono da conversa até que o produto aprove sua semântica de latência; Fast
mode também precisa de avaliação própria.

### 3.1 Alias e snapshots

O alias `gpt-5.6` roteia atualmente para `gpt-5.6-sol`. Os perfis do Pedro devem
usar o slug explícito do tier (`-sol`, `-terra` ou `-luna`) para não confundir
um alias de família com a escolha operacional. Fonte:
[guia do GPT-5.6][latest-model].

A referência da API avisa que comportamento de prompting pode mudar entre
snapshots e recomenda versões fixadas e evals para consistência. Porém, as
páginas atuais de Sol, Terra e Luna listam somente o próprio slug sem data como
“current snapshot”; esta pesquisa não encontrou um snapshot imutável datado
para a família 5.6. Portanto:

- não alegar pinning imutável onde a documentação não o oferece;
- guardar modelo solicitado e modelo realmente retornado;
- registrar a data da aprovação e os hashes do perfil;
- executar canário/regressão após mudança observada ou anúncio de modelo;
- manter rollback para o último perfil aprovado.

Fontes: [compatibilidade da API][compatibility],
[Sol][sol], [Terra][terra] e [Luna][luna].

## 4. Capacidades documentadas e limites

| Capacidade | Evidência oficial | O que ainda precisa de gate |
|---|---|---|
| Responses API | Os três modelos suportam o endpoint `responses`; a OpenAI o recomenda para reasoning, ferramentas e fluxos multi-turno. | Contrato do orquestrador, timeout, retries, observabilidade e custo real. |
| Structured Outputs | Responses aceita `text.format` com JSON Schema e `strict: true`; Structured Outputs adere ao schema, ao contrário do JSON mode, que garante apenas JSON válido. | Cada schema concreto do Pedro deve pertencer ao subconjunto suportado e passar em testes. |
| Function calling | Ferramentas customizadas suportam `strict: true`; o fluxo oficial devolve uma proposta de chamada para o aplicativo executar. | Nome da ferramenta, argumentos, evidência, autorização, estado, `expected_version` e efeito correto. |
| Várias ferramentas | O modelo pode propor zero, uma ou várias chamadas; `tool_choice` limita seleção e `parallel_tool_calls: false` restringe a zero ou uma por turno. | Ordem, dependência e concorrência seguras no domínio. |
| Continuidade | `previous_response_id`, replay manual de itens ou Conversations API permitem contexto multi-turno. | O banco continua canônico; resumos e IDs da API não podem substituir evidência ou estado operacional. |
| Instruções | `instructions` controla o turno, mas não é carregado automaticamente quando se usa `previous_response_id`. | Reenviar a versão estável compilada em cada turno e registrar sua versão. |
| Streaming | `stream: true` usa Server-Sent Events tipados, incluindo deltas de texto, recusa, argumentos de ferramenta e eventos finais. | Não enviar deltas não validados ao WhatsApp nem executar ferramenta antes da validação final. |
| Contexto | Cada candidato publica 1.050.000 tokens de contexto, 922.000 de entrada e 128.000 de saída. | Política de truncation, resumo, custo e latência com conversas longas. |
| Português | O catálogo afirma capacidade multilíngue para os modelos atuais. | Não há garantia oficial específica de `pt-BR`; fluência, estilo do Pedro, abreviações, voz imobiliária e entendimento local exigem avaliação humana. |

Fontes da tabela:
[Responses API][responses],
[Structured Outputs][structured-outputs],
[function calling estrito][strict-functions],
[controle de ferramentas][tool-choice],
[chamadas paralelas][parallel-functions],
[estado de conversa][conversation-state],
[migração multi-turno][multi-turn],
[streaming][streaming] e [modelos][models].

### 4.1 Regras do JSON Schema estrito

O contrato das ferramentas deve respeitar o subconjunto documentado:

- a raiz deve ser um objeto, não `anyOf`;
- todos os campos devem ser `required`; opcionalidade é representada por união
  com `null`;
- cada objeto precisa de `additionalProperties: false`;
- há limite de 5.000 propriedades de objetos e profundidade de 10 níveis;
- são aceitos os tipos básicos, arrays, enums e `anyOf`, mas construções como
  `allOf`, `not`, `if/then/else`, `dependentRequired` e `dependentSchemas` não
  são suportadas;
- um schema não aceito com `strict: true` causa erro de API;
- o primeiro request com um schema novo pode ter latência adicional de
  processamento.

Fonte: [schemas suportados][supported-schemas].

`strict: true` deve ser explícito. A documentação de function calling informa
que, quando `strict` é omitido, a API tenta normalizar o schema e pode cair
silenciosamente para o modo não estrito se ele for incompatível. Um perfil
aprovado não pode aceitar esse downgrade. Fonte:
[function calling estrito][strict-functions].

Mesmo quando o schema é obedecido, uma resposta pode terminar em recusa ou
ficar incompleta por limite de tokens. O consumidor precisa inspecionar status,
`incomplete_details` e conteúdo de recusa antes de aceitar a saída. Fonte:
[boas práticas de Structured Outputs][structured-tips].

### 4.2 Ferramentas e fronteira de efeito

No fluxo oficial, o aplicativo envia as ferramentas, o modelo devolve
`function_call`, o aplicativo executa código e devolve `function_call_output`;
o modelo não executa por si a função customizada. Fonte:
[fluxo de function calling][function-flow].

Para o primeiro piloto, a decisão conservadora é:

- expor em cada turno somente a allowlist necessária;
- usar `strict: true` em todas as funções;
- começar com `parallel_tool_calls: false`;
- permitir no máximo uma proposta de efeito por rodada;
- validar schema, ferramenta, modo, política, evidência e `expected_version`;
- persistir a decisão antes de enfileirar efeito externo;
- recalcular quando o estado mudou, sem repetir comando antigo.

Isso é uma decisão GrillStudio baseada na arquitetura do repositório, não uma
limitação da OpenAI. Chamadas múltiplas podem ser reavaliadas depois que testes
provarem ordenação, atomicidade, rollback e idempotência.

### 4.3 Continuidade e instruções

Há três mecanismos documentados: encadear por `previous_response_id`, reenviar
itens anteriores manualmente ou usar uma Conversation persistente. A
documentação também informa que as instruções de alto nível do request anterior
**não** são transportadas por `previous_response_id`; elas devem ser enviadas
de novo. Fontes: [migração multi-turno][multi-turn] e
[estado de conversa][conversation-state].

O contrato do Pedro deve preferir contexto explícito compilado do banco:

- reconstruir a entrada a partir de estado, evidências e versões canônicas;
- reenviar `instructions` em cada turno;
- usar continuidade da API apenas como otimização de contexto/raciocínio;
- nunca usar memória do provedor para decidir opt-out, ownership, capacidade,
  call, disponibilidade, preço ou ação já executada;
- incluir o identificador da resposta anterior somente enquanto ele continuar
  coerente com a versão comportamental e factual atribuída.

O guia do GPT-5.6 documenta `reasoning.effort` em `none`, `low`, `medium`,
`high`, `xhigh` e `max`, com `medium` como default, e recomenda testar a mesma
configuração e um nível abaixo em tarefas representativas. Assim, o esforço
também faz parte do perfil aprovado; mais reasoning não é automaticamente
melhor quando latência e custo importam. Fonte:
[guia do GPT-5.6][latest-model].

## 5. Gate objetivo de produção

A OpenAI recomenda definir objetivo, dataset e métricas, comparar execuções e
avaliar continuamente a cada mudança; conjuntos devem conter casos típicos, de
borda e adversariais, com avaliadores humanos especialistas. Fonte:
[boas práticas de avaliação][evals].

O GrillStudio já fixa o mínimo vinculante:

- pelo menos 50 conversas/casos representativos;
- 90% ou mais em extração da qualificação;
- 90% ou mais em próxima ação;
- 100% nos casos críticos de opt-out, privacidade, fraude, pergunta direta
  sobre IA e promessa proibida;
- intervalo por categoria visível e amostra humana cega em conversas reais do
  modo sombra;
- reavaliação depois de troca de modelo ou grande mudança de persona.

Fonte:
[Backlog, Testes e Piloto v1](../product/Backlog-Testes-e-Piloto-v1.md),
seções 6 e 8.

### 5.1 Compatibilidade técnica — bloqueia antes da qualidade

Cada perfil só entra na regressão de qualidade se alcançar:

- 100% dos schemas aceitos pela API com `strict: true`, sem normalização para
  `strict: false`;
- 100% das respostas classificáveis como mensagem, chamada válida, recusa,
  incompleta ou erro — nenhum estado desconhecido;
- 100% das ferramentas propostas dentro da allowlist do caso;
- 100% dos argumentos parseáveis e validados no backend;
- zero efeito real no simulador;
- zero ferramenta proibida executável;
- reprodução auditável com modelo solicitado/efetivo, parâmetros, versões,
  schema, ferramentas, tokens, custo, latência e motivo de fallback.

Esses percentuais são apropriados para compatibilidade binária e segurança de
execução; eles não substituem as métricas semânticas de 90%.

### 5.2 Qualidade semântica — aprova o perfil

O conjunto deve pontuar separadamente:

1. extração por campo: correto, incorreto ou deveria se abster, com cobertura
   separada;
2. próxima ação por turno contra o conjunto de ações aceitáveis;
3. ferramenta e argumentos semanticamente corretos;
4. evidência suficiente para cada alteração de qualificação;
5. factualidade, abstenção e ausência de promessa/invenção;
6. naturalidade em `pt-BR`, estilo da persona, mensagens curtas e uma pergunta
   por vez;
7. consistência em conversa longa, mudança de critério e múltiplas mensagens;
8. todos os erros críticos da seção 31.1 da
   [Especificação do Produto](../product/Especificacao-do-Produto-v1.md).

Sol, Terra e Luna passam pelo mesmo gate. Um modelo mais barato não recebe
tolerância maior, e Sol não recebe aprovação por reputação. Quando modelos
empatam no gate funcional, custo e latência medidos decidem.

### 5.3 Performance e custo — limites ainda abertos

Registrar por perfil:

- latência até resposta completa, p50/p95/p99;
- tempo do primeiro evento quando streaming for usado;
- tokens de entrada, cache, reasoning e saída;
- custo por turno, conversa e caso concluído;
- taxa de retry e fallback;
- incidência de recusa, incompletude e estouro de contexto.

Não há número oficial de latência que garanta o comportamento no workload do
Pedro. A OpenAI só posiciona Terra/Luna relativamente para custo/volume e
recomenda comparação representativa. O dono do produto ainda precisa definir o
SLO máximo e o orçamento antes de promover um perfil.

## 6. Matriz de retry, fallback e pausa

Fallback só ocorre depois dos retries configurados e somente quando:

1. primário e secundário estão aprovados para o mesmo contrato;
2. a entrada, versões, schemas, allowlist e `expected_version` são idênticos;
3. nenhuma ferramenta foi aceita/executada e nenhuma mensagem foi enfileirada;
4. a falha foi classificada como transitória;
5. a chave `ai-turn:{conversation_id}:{last_inbound_message_id}:{context_version}`
   impede duas decisões concorrentes.

| Falha observada | Retry do mesmo perfil | Fallback aprovado | Decisão |
|---|---|---|---|
| Timeout antes de resposta ou conexão interrompida | Sim, espera breve e limite total | Sim, após esgotar retries e antes de efeito | Transitória; registrar falha e modelo efetivo. |
| `429` de rate limit temporário | Sim, respeitar `Retry-After`; sem ele, backoff exponencial com jitter | Sim, após limite | Falhas também consomem limite; não repetir indefinidamente. |
| `500`/`503` ou indisponibilidade transitória | Sim, espera breve e limite | Sim | Caminho previsto no produto. |
| `400`/`BadRequest`, schema ou parâmetro inválido | Não | Não | Defeito de contrato/configuração; pausar perfil e alertar. |
| `401`, permissão ou recurso inexistente | Não | Não | Corrigir chave, organização, acesso ou ID; fallback pode mascarar incidente de configuração. |
| Cota, crédito, billing ou spend limit | Não | Não | A documentação afirma que retry não restaura acesso; alertar dono. |
| Resposta `incomplete`, limite de tokens ou recusa | Não automaticamente | Não às cegas | Classificar e pausar/escalar; aumentar limite ou trocar modelo altera o perfil e exige decisão testada. |
| Saída estruturalmente inválida ou `strict: false` | Não | Não | Incompatibilidade técnica; a especificação manda pausar. |
| Ferramenta fora da allowlist ou argumento sem evidência | Não | Não | Falha de segurança/semântica. |
| Opt-out, privacidade, fraude, pagamento, documento sensível, promessa proibida ou pergunta direta sobre IA | Não | Não | Aplicar regra determinística e escalonamento; nenhum modelo deve improvisar. |
| `expected_version` divergente ou estado mudou | Não repetir comando | Não | Recarregar estado e recalcular um novo turno. |
| Timeout/erro depois de ferramenta, outbox ou envio | Não até reconciliar | Não | Resultado ambíguo pode duplicar ou contradizer efeito; reconciliar por idempotência/estado canônico. |
| Queda de qualidade sem erro de transporte | Não | Não | Pausar/escalar e abrir regressão; fallback por “sensação” não é determinístico. |

Fontes externas da classificação:
[erros da API][errors] e
[retry com backoff][rate-limits].
Fontes internas:
[Arquitetura Técnica v1](../product/Arquitetura-Tecnica-v1.md), seção 9, e
[Eventos, Filas e Automações v1](../product/Eventos-Filas-e-Automacoes-v1.md),
seções 9 e 10.

O SDK oficial pode já repetir erros elegíveis e respeitar `Retry-After`.
Retries na aplicação precisam contar os retries internos para manter limite de
tentativas e tempo total. Fonte: [rate limits][rate-limits].

## 7. Decisão que esta pesquisa permite registrar

Pode ser registrado agora:

- candidatos iniciais: `gpt-5.6-sol`, `gpt-5.6-terra` e `gpt-5.6-luna`;
- todos possuem os primitivos de API exigidos em nível documental;
- `gpt-5.6-sol` preserva o papel de candidato primário já previsto no produto,
  `gpt-5.6-terra` é o candidato inicial a fallback e desafiante de
  custo/latência, e `gpt-5.6-luna` uma hipótese para tarefas auxiliares;
- perfil completo, não slug isolado, é a unidade de aprovação;
- fallback é permitido somente para falha transitória classificada, entre
  perfis aprovados e antes de qualquer efeito;
- falha estrutural, semântica ou de segurança pausa;
- continuidade da Responses API não substitui o banco como estado canônico.

Permanece bloqueado até implementação/teste:

- afirmar compatibilidade dos schemas concretos;
- aprovar qualquer perfil para produção;
- escolher definitivamente primário e secundário;
- declarar qualidade em português brasileiro;
- definir esforço de raciocínio, `max_output_tokens` e política de contexto;
- definir SLO de latência e orçamento por conversa;
- liberar chamadas paralelas;
- afirmar snapshot imutável para GPT-5.6.

## Referências OpenAI

[models]: https://developers.openai.com/api/docs/models
[latest-model]: https://developers.openai.com/api/docs/guides/latest-model
[sol]: https://developers.openai.com/api/docs/models/gpt-5.6-sol
[terra]: https://developers.openai.com/api/docs/models/gpt-5.6-terra
[luna]: https://developers.openai.com/api/docs/models/gpt-5.6-luna
[pricing]: https://developers.openai.com/api/docs/pricing
[responses]: https://developers.openai.com/api/reference/resources/responses/methods/create
[structured-outputs]: https://developers.openai.com/api/docs/guides/structured-outputs#structured-outputs-vs-json-mode
[supported-schemas]: https://developers.openai.com/api/docs/guides/structured-outputs#supported-schemas
[structured-tips]: https://developers.openai.com/api/docs/guides/structured-outputs#tips-for-your-json-schema
[strict-functions]: https://developers.openai.com/api/docs/guides/function-calling#strict-mode
[tool-choice]: https://developers.openai.com/api/docs/guides/function-calling#tool-choice
[parallel-functions]: https://developers.openai.com/api/docs/guides/function-calling#parallel-function-calling
[function-flow]: https://developers.openai.com/api/docs/guides/function-calling#the-tool-calling-flow
[conversation-state]: https://developers.openai.com/api/docs/guides/conversation-state#passing-context-from-the-previous-response
[multi-turn]: https://developers.openai.com/api/docs/guides/migrate-to-responses#3-update-multi-turn-conversations
[streaming]: https://developers.openai.com/api/docs/guides/streaming-responses#enable-streaming
[compatibility]: https://developers.openai.com/api/reference/overview#backwards-compatibility
[evals]: https://developers.openai.com/api/docs/guides/evaluation-best-practices#design-your-eval-process
[errors]: https://developers.openai.com/api/docs/guides/error-codes
[rate-limits]: https://developers.openai.com/api/docs/guides/rate-limits#retrying-with-exponential-backoff
