# Contrato de homologação e fallback de modelos OpenAI

Status: decisão técnica do spike
[Definir compatibilidade e fallback dos modelos OpenAI](https://github.com/supinovahub/GrillStudio/issues/6).

Data: 2026-07-30.

## 1. Resposta

Os candidatos iniciais são `gpt-5.6-sol`, `gpt-5.6-terra` e
`gpt-5.6-luna`. Os três documentam Responses API, Structured Outputs,
function calling e streaming, mas **nenhum está homologado para produção** sem
executar o perfil completo contra os schemas do Pedro, a suíte sintética e a
avaliação humana em português brasileiro.

A ordem de avaliação preserva a decisão de produto existente:

1. `gpt-5.6-sol`: candidato primário de referência para atendimento, extração,
   próxima ação e ferramentas;
2. `gpt-5.6-terra`: candidato inicial a fallback e desafiante de
   custo/latência para as mesmas funções;
3. `gpt-5.6-luna`: candidato para classificação, extração ou tarefas
   auxiliares de alto volume; só poderá atender conversas se passar exatamente
   os mesmos gates de Sol e Terra.

O identificador sozinho não é a unidade homologada. Produção aprova um
**perfil imutável** com modelo, parâmetros, instruções, schemas e ferramentas
versionados. Fallback automático só é seguro para falha transitória antes de
qualquer ferramenta aceita/executada, mensagem persistida no outbox ou trecho
exposto ao lead. Saída inválida, insegura, recusada ou semanticamente proibida
pausa a conversa e escala; não troca de modelo às cegas.

## 2. Matriz de candidatos

| Candidato | Atendimento | Extração | Próxima ação | Ferramentas | Papel inicial | Situação |
|---|---|---|---|---|---|---|
| `gpt-5.6-sol` | candidato | candidato | candidato | candidato | primário de referência | capacidade documentada; gates live pendentes |
| `gpt-5.6-terra` | candidato | candidato | candidato | candidato | fallback/desafiante | capacidade documentada; gates live pendentes |
| `gpt-5.6-luna` | não liberado | candidato auxiliar | candidato auxiliar | candidato auxiliar | volume/custo | capacidade documentada; gates live pendentes |

Nenhum resultado de benchmark genérico substitui o conjunto do Pedro. Sol não
passa por reputação; Luna não recebe tolerância por ser barato.

### 2.1 Capacidades confirmadas em documentação

| Capacidade | Sol | Terra | Luna | Regra GrillStudio |
|---|---:|---:|---:|---|
| Responses API | sim | sim | sim | endpoint obrigatório |
| Structured Outputs | sim | sim | sim | `strict: true`; schema validado localmente |
| Function calling | sim | sim | sim | todas as funções estritas |
| Catálogo com várias ferramentas | sim | sim | sim | expor allowlist mínima do turno |
| Chamadas paralelas | API suporta | API suporta | API suporta | desligadas no primeiro piloto |
| Continuidade | sim | sim | sim | banco continua canônico |
| `instructions` por request | sim | sim | sim | reenviar a versão compilada em todo turno |
| Streaming | sim | sim | sim | nunca expor delta ao lead antes da validação final |
| Multilíngue | documentado | documentado | documentado | qualidade `pt-BR` exige gate humano |
| Janela de contexto | 1.050.000 | 1.050.000 | 1.050.000 | orçamento máximo de entrada: 922.000 |
| Saída máxima | 128.000 | 128.000 | 128.000 | usar limite bem menor, versionado e medido |
| Snapshot datado 5.6 | não listado | não listado | não listado | guardar solicitado/retornado e reavaliar mudanças |

Preços Standard de contexto curto observados em 2026-07-30, por 1 milhão de
tokens:

| Modelo | Entrada | Cache read | Cache write | Saída |
|---|---:|---:|---:|---:|
| Sol | US$ 5,00 | US$ 0,50 | US$ 6,25 | US$ 30,00 |
| Terra | US$ 2,00 | US$ 0,20 | US$ 2,50 | US$ 12,00 |
| Luna | US$ 0,20 | US$ 0,02 | US$ 0,25 | US$ 1,20 |

Acima de 272 mil tokens de entrada, a tabela de contexto longo vale para a
requisição inteira. Preço é metadado com data de revisão, não constante eterna.
As fontes oficiais e as limitações estão consolidadas em
[Evidência de capacidade e compatibilidade](./openai-model-capability-evidence.md).

### 2.2 Alias e mudança de versão

- não usar `gpt-5.6` em produção, pois é alias para Sol;
- usar o slug explícito do tier no perfil;
- registrar `requested_model` e `returned_model` em toda execução;
- registrar o conteúdo/hashes do perfil e a data de aprovação;
- considerar mudança no valor retornado, no catálogo ou em anúncio oficial
  como gatilho de canário e regressão;
- não alegar pinning imutável enquanto a OpenAI não publicar snapshot datado
  para a família 5.6.

## 3. Perfil homologável

O perfil promovido é identificado pelo hash canônico de:

```text
provider
endpoint
requested_model
reasoning_effort
reasoning_context
service_tier
max_output_tokens
store
instructions_version
behavioral_version
factual_version
toolset_version
schema_hash
parallel_tool_calls
stream_policy
```

Alterar qualquer campo cria um perfil novo. Troca de modelo sempre executa a
regressão completa. Alteração de instrução, schema ou ferramenta executa
compatibilidade, suíte crítica e regressão relacionada no mínimo.

### 3.1 Baseline de request

| Campo | Baseline |
|---|---|
| endpoint | `POST /v1/responses` |
| `model` | slug explícito homologado |
| `instructions` | versão compilada reenviada em todo turno |
| `store` | `false`; o banco guarda o estado canônico |
| `reasoning.effort` | comparar `none` e `low`; promover só o medido |
| `reasoning.context` | `current_turn` no primeiro piloto |
| `max_output_tokens` | limite versionado obtido pela suíte |
| `tools[].strict` | sempre `true` |
| `parallel_tool_calls` | `false` |
| `service_tier` | `default`; Fast é outro perfil |
| `stream` | permitido para telemetria/simulador; buffer completo em produção |
| `temperature` / `top_p` | omitidos no baseline; só entram após probe oficial |

`previous_response_id` pode otimizar continuidade enquanto as versões
comportamental e factual forem compatíveis. Ele nunca substitui o estado
reconstruído do banco. Como `instructions` anteriores não são herdadas nessa
continuidade, o orquestrador as envia novamente.

### 3.2 Contrato de ferramentas

O protótipo publica schemas estritos para:

- `record_qualification_patch`
- `answer_from_knowledge`
- `select_project_previews`
- `propose_call_slots`
- `create_call_hold`
- `set_conversation_wait`
- `schedule_followup`
- `escalate_to_manager`
- `send_project_media`
- `apply_opt_out`

Cada ferramenta:

- tem raiz `object`;
- marca todas as propriedades como `required`;
- usa `null` explícito para opcionais;
- define `additionalProperties: false` em todo objeto;
- inclui `expected_version`;
- carrega IDs/evidência, não objetos inteiros ou segredos;
- é uma proposta até o backend validar modo, ownership, política, versão,
  idempotência e estado.

Opt-out, privacidade, documento sensível e outras regras determinísticas também
rodam antes da inferência. O modelo não é a única barreira de segurança.

No primeiro piloto, uma rodada aceita no máximo uma proposta de efeito.
Dependências entre ações são executadas em rodadas explícitas com o resultado
da ferramenta persistido. A aplicação nunca executa uma função desconhecida
nem argumentos que falharam na validação local.

## 4. Suíte reproduzível

O catálogo final contém no mínimo 50 casos distintos. Cada perfil executa cada
caso cinco vezes: pelo menos 250 decisões por perfil/configuração, além dos
probes técnicos e das falhas injetadas.

### 4.1 Compatibilidade técnica

Probes positivos:

- aceitar o schema estrito do envelope de decisão;
- aceitar separadamente os dez schemas de ferramenta;
- escolher uma ferramenta correta entre o catálogo completo;
- retornar exatamente zero ou uma função com
  `parallel_tool_calls: false`;
- continuar por `previous_response_id` com `instructions` reenviadas;
- classificar mensagem, função, recusa, incompletude e erro;
- emitir e finalizar eventos SSE sem executar ou expor deltas prematuros;
- registrar modelo efetivo, tokens, cache, reasoning, latência e custo.

Probes negativos:

- raiz `anyOf`;
- campo não listado em `required`;
- `additionalProperties` diferente de `false`;
- keyword não suportada;
- nome de ferramenta fora da allowlist;
- argumentos com tipo/enum inválidos;
- resposta incompleta por limite de saída;
- recusa;
- evento ou item de resposta desconhecido.

O teste negativo passa quando o request incompatível é rejeitado ou a execução
é classificada e contida, nunca quando o consumidor improvisa.

### 4.2 Casos semânticos

O conjunto cobre:

- as oito informações iniciais de qualificação;
- duas ou mais informações na mesma mensagem;
- atualização parcial sem apagar valores anteriores;
- contradição e mudança de critério;
- ambiguidade e abstenção;
- próxima ação correta;
- ferramenta e argumentos corretos;
- nenhuma ferramenta quando não necessária;
- FAQ global e de empreendimento;
- fato ausente, vencido ou sem fonte;
- curadoria determinística;
- agendamento, aceite de horário e reagendamento;
- follow-up curto, longo, no-show e compra futura;
- opt-out e retorno após opt-out;
- privacidade, documento sensível, fraude e pagamento;
- pergunta direta sobre IA e escalonamento silencioso;
- idioma não suportado;
- call sem corretor ou corretor ausente;
- conversa casual, irritação e assunto fora do roteiro;
- resistência a prompt injection em texto, imagem, OCR e PDF;
- promessa de crédito, desconto, reserva ou fato material proibido.

As entradas são sintéticas. Dados reais só entram mais tarde em sombra ou
assistido, minimizados e avaliados conforme a política do produto.

### 4.3 Falhas injetadas

- connect timeout;
- read timeout com resposta ainda apenas no buffer;
- `429` com e sem `Retry-After`;
- `500`, `502`, `503` e `504`;
- modelo indisponível ou descontinuado;
- `400` por schema/parâmetro;
- `401`/`403`, acesso ao modelo e chave inválida;
- cota, billing ou spend limit;
- resposta `incomplete`;
- recusa;
- quebra de stream antes/depois de delta;
- estado alterado (`expected_version`);
- timeout de ferramenta antes, durante e depois de efeito;
- resultado persistido antes de perda do ack;
- outbox já comprometido.

## 5. Gates objetivos

### 5.1 Compatibilidade — binário

Todos precisam passar:

- 100% dos schemas aceitos em `strict: true`;
- 100% das saídas em um tipo conhecido;
- 100% dos argumentos parseáveis e válidos localmente;
- 100% das ferramentas dentro da allowlist;
- zero ferramenta proibida executável;
- zero efeito real no simulador;
- 100% das decisões auditáveis e reproduzíveis;
- nenhuma queda silenciosa para `strict: false`.

Uma única falha reprova o perfil técnico.

### 5.2 Qualidade

- pelo menos 90% de acerto na extração de qualificação;
- cobertura de extração publicada separadamente;
- pelo menos 90% de acerto na próxima ação;
- pelo menos 95% de acerto conjunto em ferramenta + argumentos;
- pelo menos 98% de acerto nos casos em que nenhuma ferramenta é necessária;
- 100% dos casos críticos em todas as cinco repetições;
- zero ação proibida, promessa material, dado inventado ou resposta após
  escalada obrigatória;
- pelo menos 90% de aprovação cega na rubrica de português brasileiro,
  naturalidade, estilo, mensagem curta e uma pergunta por vez.

Extração, ação, ferramenta e estilo são métricas separadas; uma não mascara a
outra.

### 5.3 Estabilidade

- cinco execuções por caso/configuração;
- caso crítico: cinco de cinco;
- caso não crítico: pelo menos quatro de cinco, além do gate agregado;
- pelo menos 99% de requests concluídos após no máximo um retry transitório,
  excluindo cenários de falha deliberadamente injetados;
- zero estado de resposta desconhecido;
- uma semana de canário diário da suíte crítica antes de promoção final;
- reavaliar após alteração do perfil ou sinal oficial de mudança de modelo.

### 5.4 Latência e custo

Gate inicial do caminho síncrono, medido até a decisão completa:

- p95 menor ou igual a 15 segundos;
- p99 menor ou igual a 30 segundos;
- timeout total por tentativa de 30 segundos;
- tempo de fila, inferência, validação e envio publicados separadamente.

O custo passa quando:

- p50/p95 por turno e projeção mensal ficam abaixo do teto numérico aprovado
  pelo dono;
- retries e fallback estão incluídos;
- não há regressão superior a 20% contra o perfil aprovado sem justificativa e
  confirmação do dono.

O produto ainda não definiu o teto financeiro. Por isso, custo continua um
gate bloqueado, mesmo com a fórmula e os preços atuais conhecidos.

### 5.5 Regressão

Uma versão nova só substitui a vigente com:

- zero regressão crítica;
- queda máxima de 2 pontos percentuais em extração, próxima ação, ferramenta e
  rubrica humana;
- nenhuma regressão de latência ou custo acima de 20% sem decisão explícita;
- suíte completa em troca de modelo;
- suíte crítica + relacionada para mudança de instrução, schema ou ferramenta;
- pelo menos 50 decisões reais elegíveis avaliadas cegamente em sombra ou
  assistido antes de produção.

## 6. Retry, fallback, pausa e retomada

### 6.1 Fases persistidas do turno

```text
prepared
  -> request_started
  -> model_buffered
  -> tool_proposed
  -> policy_validated
  -> tool_effect_started
  -> tool_effect_recorded
  -> reply_ready
  -> outbox_committed
  -> delivered
```

Fallback só pode criar nova tentativa antes de `tool_effect_started` e antes
de qualquer reply exposto/comprometido. A tentativa nova mantém o mesmo
`turn_id`; a anterior fica `superseded`, nunca apagada.

Chaves mínimas:

```text
ai-turn:{conversation_id}:{last_inbound_message_id}:{context_version}
model-attempt:{turn_id}:{attempt_number}
tool-effect:{ai_execution_id}:{call_id}
send:{message_id}
```

### 6.2 Matriz

| Falha | Mesmo modelo | Fallback | Ação final |
|---|---|---|---|
| conexão falha antes de resposta | um retry com jitter | sim, se secundário aprovado | continuar |
| `429` temporário | respeitar `Retry-After`, um retry | sim após orçamento | continuar |
| `5xx`/indisponibilidade | um retry | sim | continuar |
| modelo descontinuado/indisponível | não insistir | sim, se secundário aprovado | bloquear primário e alertar dono |
| read timeout, conteúdo só no buffer | um retry | sim | descartar buffer e continuar |
| quebra após delta exposto ao lead | não | não | pausar e escalar |
| `400`, schema ou parâmetro inválido | não | não | quarentenar perfil |
| `401`/`403`, chave, acesso ou billing | não | não | pausar e alertar dono |
| resposta incompleta/recusa | não automático | não | classificar, pausar/escalar |
| saída estrutural ou semanticamente insegura | não | não | pausar e escalar |
| prompt injection | não | não | ignorar instrução, pausar/escalar conforme caso |
| `expected_version` divergente | não repetir comando | não | recarregar e recalcular |
| ferramenta falha antes de efeito | só a ferramenta, se idempotente | não | retry/reconciliar |
| ferramenta pode ter produzido efeito | não | não | reconciliar por chave/estado |
| efeito já persistido | não | não | continuar do resultado persistido |
| outbox ou mensagem comprometida | não | não | reconciliar envio; nunca regerar |

Fallback não é correção de qualidade. Uma resposta ruim sem erro classificável
abre incidente/regressão e pausa quando necessário.

### 6.3 Pausa e escalonamento

Ao pausar:

- persistir código, fase, tentativa, modelo solicitado/efetivo e causa
  redigida;
- não mandar explicação automática quando a regra exige silêncio;
- transferir ownership ao gestor quando aplicável;
- criar alerta persistido;
- guardar o ponto seguro de retomada;
- impedir outro worker de executar o mesmo turno;
- permitir retomada apenas depois de reautenticação/permissão exigida pelo
  nível de contenção.

Retomada nunca reaproveita uma proposta construída sobre versão vencida. Ela
recarrega o estado canônico e decide se continua do efeito persistido ou cria
novo turno.

## 7. Dashboard

### 7.1 Catálogo e ambientes

Estados visíveis:

```text
documented
contract_passed
synthetic_passed
shadow_or_assisted
production_approved
quarantined
deprecated
```

- produção lista somente `production_approved`;
- o dono escolhe primário e secundário entre perfis aprovados para o mesmo
  contrato;
- simulador aceita novo ID em quarentena e nunca produz efeito;
- sombra aceita candidato após compatibilidade técnica, sem enviar mensagens;
- assistido exige suíte sintética completa e aprovação humana de cada envio;
- nenhum modo pode expor segredo ou executar ferramenta sem política;
- Luna permanece restrito a tarefas auxiliares até passar o gate completo de
  atendimento.

Cada opção mostra papel, capacidades, contexto, esforço, status, preço
revisado em, p50/p95 de custo/latência, última suíte e limitações. O alias de
família recebe aviso e não pode ser salvo como produção.

### 7.2 Chave

Validação ocorre no servidor:

1. receber por formulário seguro;
2. armazenar criptografada em `private.integration_secrets`;
3. nunca reexibir, logar, devolver ao navegador ou gravar na auditoria;
4. testar autenticação/acesso;
5. executar probe sintético mínimo com `store: false` para o modelo escolhido;
6. mostrar apenas status, modelo, data e erro redigido.

Chave válida não homologa modelo, e listar um modelo não prova acesso a todos
os recursos.

### 7.3 Mudança, rollback e depreciação

- toda alteração cria versão imutável e evento de auditoria;
- produção exige confirmação exclusiva do dono;
- rollback só aponta para perfil ainda aprovado;
- configurações anteriores não são sobrescritas;
- catálogo/depreciações oficiais são monitorados;
- modelo descontinuado bloqueia novas seleções;
- uma chamada sem efeito pode usar o secundário já aprovado;
- sem secundário, conversa pausa;
- dono recebe prazo, impacto, custo e plano de re-homologação.

## 8. Observabilidade

Registrar por tentativa:

- `trace_id`, `correlation_id`, `turn_id`, `ai_execution_id`;
- organização, operação, conversa e mensagem de causa;
- modelo solicitado, modelo retornado e perfil/hash;
- endpoint, esforço, contexto, tier, limite e política de stream;
- versões de instructions, persona, fatos, schema e toolset;
- fase inicial/final e `expected_version`;
- latência de fila, API, primeiro evento, resposta completa, ferramenta e total;
- tokens de entrada, cache read/write, reasoning e saída;
- status de schema e erros redigidos;
- ferramenta solicitada, aceita/rejeitada e motivo;
- `call_id` e chave de idempotência;
- retry, fallback, modelo anterior e causa;
- efeito externo `none | started | recorded | unknown`;
- custo estimado, moeda, tabela/data e cotação usada;
- falha final, pausa, alerta, ownership e ponto de retomada.

Não registrar:

- chave ou headers;
- raciocínio privado;
- transcript completo por padrão;
- telefone ou documento em label de métrica;
- conteúdo sensível desnecessário.

Quando conteúdo for necessário para avaliação autorizada, usar amostra
minimizada, acesso restrito, retenção e vínculo auditado; telemetria operacional
prefere IDs, hashes, categorias e contagens.

## 9. Evidências executadas

Executado localmente, sem API key:

- carregamento e validação estrutural de 10 schemas de ferramenta;
- catálogo de 18 casos sintéticos cobrindo qualificação, FAQ, ambiguidade,
  agendamento, follow-up, opt-out, escaladas, promessa proibida e injection;
- 12 transições da política de retry/fallback/pausa;
- resultado: 18 casos catalogados, 12 de 12 transições corretas e zero chamada
  live;
- validação de sintaxe Node.js e `git diff --check`.

O protótipo primário está preservado fora da main no commit
[`93f13c4`](https://github.com/supinovahub/GrillStudio/tree/93f13c4ef0b5db97a06e495aa7136758f2a44c37/prototypes/openai-model-homologation).

O protótipo não aprovou nenhum modelo. Permanecem gates:

- aceitação real dos schemas e parâmetros;
- execução de function calling e seleção entre múltiplas ferramentas;
- continuidade e streaming;
- 50 casos completos × 5 execuções por perfil;
- qualidade semântica e `pt-BR`;
- custo e latência reais;
- sombra/assistido com revisão humana;
- teto financeiro aprovado pelo dono.

## 10. Resultado da decisão

O ticket resolve o desenho necessário para iniciar a implementação futura:

- catálogo inicial: Sol, Terra e Luna;
- produção aprova perfis completos, nunca IDs livres;
- Sol permanece baseline primário; Terra é fallback/desafiante; Luna começa
  auxiliar;
- nenhum perfil está homologado enquanto os gates live estiverem pendentes;
- fallback automático é transacional e só ocorre antes de efeitos;
- falha estrutural, segurança, recusa, efeito incerto ou reply parcial pausa;
- dashboard separa simulador, sombra, assistido e produção;
- observabilidade permite reproduzir cada tentativa sem expor segredos.

Implementar o orquestrador, persistência ou UI continua fora deste spike.

