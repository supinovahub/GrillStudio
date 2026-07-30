# Contrato de pesquisa da Meta WhatsApp Cloud API

Status: decisão de integração para o MVP, sem implementação, credenciais ou
validação em conta autenticada.

Data da pesquisa: 2026-07-30.

## 1. Resultado executivo

O GrillStudio deve integrar a Meta por dois ingressos independentes e nunca
tratar um envio de formulário como se fosse uma mensagem de WhatsApp:

1. o webhook `whatsapp_business_account/messages` recebe mensagens iniciadas
   pelo contato e receipts das mensagens enviadas pela operação;
2. o webhook `page/leadgen` informa uma nova submissão de Instant Form e exige
   uma leitura posterior do lead para obter `field_data`.

Uma submissão de formulário **não abre** a janela de atendimento do WhatsApp.
A documentação oficial define que a janela de 24 horas começa ou reinicia
quando a pessoa envia uma mensagem ou faz uma ligação. Fora dela, somente
templates aprovados podem ser enviados. Logo, a recuperação oficial de um
pré-lead que ainda não chamou no WhatsApp usa um template aprovado, por padrão
da categoria `MARKETING`, depois de validar consentimento versionado, número,
opt-out, conexão, template e política. Evidências:
[mensagens de serviço][service-messages], [fundamentos de templates][templates]
e [política de mensagens][business-policy].

O contrato fica fixado assim:

- Graph API versionada; `v26.0` é a versão observada nos exemplos oficiais
  atuais e será a primeira versão de fixtures, sem upgrade silencioso;
- Bearer token de system user somente no servidor, com
  `whatsapp_business_messaging` para mensagens e
  `whatsapp_business_management` para ativos da WABA;
- verificação GET do callback por `hub.verify_token` é diferente da
  autenticidade de POST, comprovada por `X-Hub-Signature-256` sobre os bytes
  exatos do corpo usando o App Secret;
- rota da conexão por `metadata.phone_number_id`, conferida com
  `entry.id` (WABA); o número exibido não é chave;
- dedupe de inbound por `(connection_id, messages.id)` e de receipt por
  `(connection_id, statuses.id, status)`, pois o envelope não oferece um ID
  único de entrega do webhook;
- resposta 200 do endpoint de envio significa apenas que a API aceitou o
  request; entrega só é provada pelos statuses `sent`, `delivered`, `read`,
  `played` ou `failed`;
- não existe chave de idempotência de envio nem endpoint público de consulta de
  uma mensagem no contrato consultado. Timeout depois do envio é resultado
  incerto e não autoriza reenvio automático;
- templates são sincronizados por ID, com nome, idioma, categoria, status,
  formato de parâmetros e componentes; somente o status atual `APPROVED`
  habilita envio;
- o idioma inicial do produto é `pt_BR`; a Meta não traduz strings nem
  variáveis;
- `user_preferences=stop`, erro `131050` e pedido textual de interrupção
  bloqueiam novas proativas. Um `resume` da Meta é evidência, mas não remove
  sozinho o opt-out mais amplo do produto;
- Click-to-WhatsApp aparece no inbound como `referral`; Instant Forms chegam
  no webhook `leadgen`. Não há ID comum universal documentado entre esses dois
  fluxos;
- a identidade do participante é uma união evolutiva: BSUID
  (`contacts[].user_id`/`messages[].from_user_id`) quando presente, e aliases
  opcionais como `wa_id`, telefone e username. O contrato não exige telefone,
  pois a Meta já documenta cenários em que `wa_id` e `from` são omitidos.

Antes de produção ainda é obrigatório validar o contrato em ativos de teste da
Meta, com número e identidades sintéticos. A seção
[17. Bloqueios e gates de produção](#17-bloqueios-e-gates-de-produção)
delimita o acesso mínimo e os aceites.

## 2. Escopo e fontes

Esta pesquisa cobre o contrato necessário para inbound direto, submissão de
formulário, recuperação oficial, envio, mídia, interativos, templates, janela
de atendimento, consentimento, erros e receipts. Não cria app, WABA, página,
formulário, número ou template; não assina webhook e não envia mensagem.

Foram usadas exclusivamente fontes primárias:

- documentação atual da
  [WhatsApp Business Platform para criar o endpoint][webhook-endpoint],
  [webhooks][webhooks], [mensagens][messages-webhook],
  [envio][service-messages], [mídia][media] e [erros][errors];
- documentação de [Business-scoped user IDs][bsuid], inclusive migração e
  `user_id_update`;
- documentação de [opt-in][opt-in] e a
  [WhatsApp Business Messaging Policy][business-policy];
- documentação de [templates][templates], [componentes][template-components],
  [idiomas][template-languages], [categorias][template-categories],
  [gerenciamento][template-management] e
  [eventos de status][template-status];
- documentação oficial da Marketing API sobre
  [recuperação de leads de Instant Forms][lead-retrieval];
- coleção pública oficial da Meta no Postman para
  [assinatura da WABA][waba-subscription] e
  [números de negócio][phone-numbers].

As páginas principais consultadas declaram atualizações entre 2026-05-21 e
2026-07-02. A página de preços foi atualizada em 2026-07-01 e já anunciava
mudanças para 2026-08-01 e 2026-10-01. Preço não entra como regra fixa deste
contrato; janela, categoria efetiva e metadados de billing são preservados.

Este documento também aplica:

- [ADR 0004](../adr/0004-conectores-de-whatsapp-e-conversa-fixa.md):
  conversa presa ao número e à identidade de origem;
- [Arquitetura Técnica v1](../product/Arquitetura-Tecnica-v1.md), seções 3.4
  e 9: adaptador comum, payload bruto e spike Meta;
- [Especificação do Produto v1](../product/Especificacao-do-Produto-v1.md),
  seções 13, 20, 21 e 36.4: Meta, consentimento, opt-out, templates e
  recuperação;
- [Eventos, Filas e Automações v1](../product/Eventos-Filas-e-Automacoes-v1.md),
  seções 9 e 10: retry, reconciliação e idempotência.

Quando este documento diz **fato Meta**, descreve o que a fonte oficial afirma.
Quando diz **decisão GrillStudio**, define o comportamento conservador da nossa
camada normalizada.

## 3. Ativos, versão, permissões e segredos

### 3.1 Identidade da conexão

Uma conexão Meta guarda no servidor:

```text
provider = meta_cloud_api
graph_api_version = v26.0
app_id
waba_id
phone_number_id
display_phone_number
verified_name
system_user_access_token_secret_ref
app_secret_ref
webhook_verify_token_secret_ref
observed_at
```

`GET /{WABA_ID}/phone_numbers` retorna `id`, `display_phone_number`,
`verified_name` e `quality_rating`; o `id` é o `phone_number_id` usado no
endpoint de envio. Evidência: [coleção oficial de números][phone-numbers].

Todos os IDs externos são strings opacas, mesmo quando um exemplo oficial os
mostra como números. `phone_number_id` é a chave externa da conexão;
`display_phone_number` e `verified_name` são metadados exibíveis e sujeitos a
mudança.

### 3.2 Versão e drift

Os exemplos atuais de mensagens, mídia e leads usam `v26.0`:
[mensagens de serviço][service-messages], [mídia][media] e
[recuperação de leads][lead-retrieval]. O adaptador inclui explicitamente a
versão no caminho:

```text
https://graph.facebook.com/v26.0/{node-or-edge}
```

Uma nova versão só entra depois de fixtures e matriz de compatibilidade. Campos
adicionais em webhook são aceitos e preservados; remoção, renome ou mudança de
tipo bloqueia promoção.

### 3.3 Permissões e segredos

O webhook de mensagens exige `whatsapp_business_messaging`; os demais webhooks
da WABA exigem `whatsapp_business_management`. Evidência:
[visão geral de webhooks][webhooks].

Para Instant Forms, a leitura completa do lead exige token de usuário ou
Página autorizado e as permissões documentadas, incluindo
`leads_retrieval`, `ads_management`, `pages_show_list`,
`pages_read_engagement` e `pages_manage_ads`; a instalação de webhook em
Página também usa `pages_manage_metadata`. Evidência:
[recuperação de leads][lead-retrieval].

Decisões:

- tokens, App Secret e verify token ficam no cofre e nunca no browser, banco
  exposto, issue, fixture, screenshot ou log;
- logs redigem `Authorization`, query strings sensíveis e qualquer campo de
  token;
- mensagens usam o menor token com `whatsapp_business_messaging`;
- sincronização de WABA/templates usa `whatsapp_business_management`;
- leitura de lead usa token de Página/system user dedicado e não reutiliza
  credencial no payload normalizado;
- a rotação de cada segredo é auditada; a versão anterior só permanece durante
  uma janela explícita de transição.

## 4. Configuração e assinatura de webhooks

### 4.1 Verificação GET

Ao configurar ou editar callback/verify token, a Meta envia:

```text
GET {callback}
?hub.mode=subscribe
&hub.challenge={challenge}
&hub.verify_token={verify_token}
```

O endpoint compara o token recebido com o segredo local e, se
`hub.mode=subscribe` e o valor forem válidos, devolve HTTP 200 com o
`hub.challenge`. Caso contrário, devolve 4xx. Esse token é uma string escolhida
pelo integrador e armazenada no servidor. Evidência:
[criação do endpoint][webhook-endpoint].

O verify token prova conhecimento durante a configuração; ele **não** prova a
origem de POSTs posteriores.

### 4.2 Autenticidade de POST

POSTs trazem:

```text
Content-Type: application/json
X-Hub-Signature-256: sha256={digest}
```

O digest é HMAC-SHA256 dos bytes exatos do corpo, usando o App Secret. A
verificação ocorre antes de parsear/persistir efeitos, com comparação em tempo
constante. Recriar JSON a partir de um objeto parseado não é válido, pois pode
alterar os bytes assinados. Evidência: [criação do endpoint][webhook-endpoint].

Fluxo de ingresso:

1. limitar método, Content-Type e corpo ao máximo oficial de 3 MB;
2. ler uma única vez os bytes brutos;
3. validar `X-Hub-Signature-256`;
4. validar envelope mínimo e conexão conhecida;
5. gravar corpo bruto privado + inbox durável;
6. responder HTTP 200;
7. normalizar e produzir efeitos de modo assíncrono e idempotente.

Assinatura ausente/malformada/inválida recebe 4xx e não entra no inbox. A Meta
documenta batches de até 1.000 updates, sem garanti-los, e retry imediato
seguido de tentativas menos frequentes por até sete dias. Duplicatas são
esperadas. Evidências: [criação do endpoint][webhook-endpoint] e
[visão geral][webhooks].

mTLS é suportado como defesa adicional no nível do app, mas HMAC é o requisito
mínimo do MVP. Allowlist de IP não substitui HMAC e pode ficar obsoleta; a
própria Meta recomenda considerar mTLS para evitar regeneração da lista.
Evidência: [visão geral][webhooks].

### 4.3 Assinaturas da WABA

O app deve ser inscrito na WABA por
`POST /{WABA_ID}/subscribed_apps`. Uma inscrição cobre os números daquela
WABA; não é necessária uma por número. Evidência:
[coleção oficial de subscriptions][waba-subscription].

Campos mínimos:

```text
messages
message_template_status_update
message_template_quality_update
message_template_components_update
template_category_update
user_preferences
user_id_update
```

`messages` cobre inbound e status outbound; os quatro campos de template
mantêm a biblioteca sincronizada; `user_preferences` informa stop/resume de
marketing; `user_id_update` mantém o vínculo histórico quando a identidade
escopada muda. A lista e a finalidade de cada campo estão na
[visão geral de webhooks][webhooks] e na documentação de [BSUID][bsuid].

## 5. Envelope, identificadores e deduplicação

### 5.1 Envelope de mensagens

O envelope comum é:

```text
object = whatsapp_business_account
entry[].id = WABA_ID
entry[].changes[].field = messages
entry[].changes[].value.messaging_product = whatsapp
entry[].changes[].value.metadata.phone_number_id
entry[].changes[].value.metadata.display_phone_number
```

Inbound contém `contacts[]` + `messages[]`; outbound contém `statuses[]`.
Evidência: [referência de mensagens][messages-webhook].

O parser percorre todas as posições de `entry`, `changes`, `messages`,
`statuses`, `user_preferences` e eventos de template. Nunca assume índice zero
ou um evento por POST.

### 5.2 Chaves externas

| Campo Meta | Uso normalizado | Regra |
|---|---|---|
| `entry.id` | `provider_waba_id` | deve corresponder à conexão |
| `metadata.phone_number_id` | `provider_phone_number_id` | roteia para o número/conexão |
| `metadata.display_phone_number` | número exibido | metadado, nunca chave |
| `contacts[].user_id` | BSUID do contato | identidade preferencial quando presente |
| `messages[].from_user_id` | BSUID do remetente | deve corresponder ao contato do mesmo evento |
| parent BSUID | alias organizacional anterior/superior | opcional; preservar quando publicado |
| `contacts[].wa_id` | alias WhatsApp legado | opcional; string opaca |
| `messages[].from` | telefone remetente observado | opcional; normalizar sem derivar de outro ID |
| `username` | alias exibível do participante | opcional; nunca chave única |
| `messages[].id` | `provider_message_id` | chave natural do inbound |
| `messages[].context.id` | mensagem contextual | relação de resposta/referência |
| `statuses[].id` | `provider_message_id` outbound | correlaciona resposta e receipts |
| `statuses[].recipient_id` | destinatário observado | string opaca; não substituir pelo contato sem conferência |
| template `id` | `provider_template_id` | chave primária da biblioteca |
| `leadgen_id` | `provider_form_submission_id` | dedupe da submissão |

A documentação de BSUID informa que `wa_id` e `from` podem ser omitidos quando
o participante usa username. Ela também trata BSUID como escopado ao business
portfolio e documenta `user_id_update`; partes do envio por BSUID ainda estão
marcadas como rollout/sujeitas a mudança. Evidência: [BSUID][bsuid].

Assim, a identidade normalizada é:

```text
ProviderIdentity {
  bsuid?
  parent_bsuid?
  wa_id?
  phone_e164?
  username?
}
```

Pelo menos um identificador aceito precisa existir. Cada valor é string opaca,
ganha intervalo de validade e pode ser ligado historicamente por evento
oficial; nenhum alias é calculado a partir de outro. O envio por BSUID só será
habilitado depois de fixture da versão/conta escolhida. Enquanto isso, a
capacidade outbound exige um destinatário aceito e comprovado pela API.

### 5.3 Chaves de efeito

```text
meta-inbound:{connection_id}:{messages.id}
meta-receipt:{connection_id}:{statuses.id}:{status}
meta-user-preference:{connection_id}:{provider_identity_key}:{category}:{value}:{timestamp}
meta-user-id-update:{waba_id}:{previous_bsuid}:{current_bsuid}:{timestamp}
meta-template-event:{waba_id}:{template_id}:{event}:{entry.time}
meta-leadgen:{page_id}:{leadgen_id}
```

Não há `provider_event_id` geral no envelope publicado. O POST bruto pode ser
guardado mais de uma vez para diagnóstico, mas as chaves acima impedem efeitos
duplicados.

## 6. Inbound normal

### 6.1 Tipos

A referência atual possui payloads dedicados para `audio`, `button`,
`contacts`, `document`, `edit`, `image`, `interactive`, `location`, `order`,
`reaction`, `revoke`, `sticker`, `system`, `text`, `unsupported` e `video`;
erros também podem aparecer no nível de `value`, `messages` ou `statuses`.
Evidência: [referência de mensagens][messages-webhook].

Envelope normalizado:

```text
InboundMessage {
  connection_id
  provider = "meta_cloud_api"
  provider_waba_id
  provider_phone_number_id
  provider_message_id
  provider_identity {
    bsuid?
    parent_bsuid?
    wa_id?
    phone_e164?
    username?
  }
  sender_phone?
  profile_name?
  occurred_at
  kind =
    text | image | document | audio | video | sticker |
    contact | location | button_reply | list_reply |
    reaction | edit | revoke | flow_reply | system | order | unsupported
  text?
  context_provider_message_id?
  attachment_ref?
  referral?
  raw_payload_ref
}
```

Regras:

- texto, imagem, documento, áudio e vídeo podem ingressar, mas somente tipos
  aprovados pela política do produto alimentam resposta autônoma;
- `button` e `interactive` são respostas do usuário. `interactive.type`
  inclui `button_reply`, `list_reply` e, para Flow concluído, `nfm_reply`;
  o MVP produz efeitos de negócio apenas para os dois primeiros;
- `reaction`, `edit` e `revoke` referenciam uma mensagem existente e viram
  eventos append-only; não reescrevem silenciosamente auditoria;
- `system`, `order`, `unsupported`, tipo novo ou corpo incompleto são
  preservados e classificados sem resposta autônoma;
- grupo, catálogo/pedido e ligações ficam fora do MVP, mesmo que a plataforma
  ofereça superfícies correspondentes;
- ausência de `messages.id`, de toda identidade do participante, timestamp ou
  conteúdo reconhecível
  classifica o evento como `unsupported_schema`, sem descartá-lo.

## 7. Mídia

### 7.1 Fatos Meta

A Meta publica:

```text
POST   /{PHONE_NUMBER_ID}/media   -> upload, retorna media ID
GET    /{MEDIA_ID}                -> metadata + URL temporária
DELETE /{MEDIA_ID}
GET    {MEDIA_URL}                -> download autenticado
```

IDs de upload expiram após 30 dias; IDs recebidos em webhook, após sete dias.
URLs de mídia expiram após cinco minutos. O download exige Bearer token.
Evidência: [documentação de mídia][media].

Limites documentados:

| Família | Tipos principais | Máximo |
|---|---|---:|
| imagem | JPEG, PNG | 5 MB |
| documento | TXT, PDF, Office/OpenXML | 100 MB |
| áudio | AAC, AMR, MP3, M4A, OGG/Opus mono | 16 MB |
| vídeo | MP4 ou 3GPP; H.264/AAC | 16 MB |
| sticker | WebP estático/animado | 100 KB/500 KB |

Inbound acima de 100 MB pode gerar erro `131052`. MIME incompatível no upload
é causa comum de `131053`. Evidências: [mídia][media] e
[códigos de erro][errors].

### 7.2 Decisão GrillStudio

Inbound:

1. persistir o webhook antes do download;
2. capturar `media_id`, MIME, hash, caption e URL, quando presentes;
3. consultar o ID e baixar com token em worker isolado;
4. validar tamanho, MIME real, extensão e SHA-256;
5. copiar para bucket privado e guardar referência canônica;
6. nunca persistir URL temporária como material definitivo;
7. falha ou expiração vira anexo indisponível + alerta, não perda da mensagem.

Outbound:

- preferir upload controlado e `media_id` para material aprovado;
- para URL, aceitar somente HTTPS de host de Storage permitido, com URL curta;
- validar os limites Meta antes do request;
- não repassar URL recebida do contato;
- imagem e PDF são o recorte autônomo inicial do produto; os demais tipos
  exigem ação/política explícita.

## 8. Click-to-WhatsApp, interativos e Flows

### 8.1 Click-to-WhatsApp

Uma mensagem de texto originada por Click-to-WhatsApp pode incluir:

```text
referral.source_url
referral.source_id       # ad ID
referral.source_type = ad
referral.body
referral.headline
referral.media_type
referral.image_url | video_url | thumbnail_url
referral.ctwa_clid
referral.welcome_message.text
```

`ctwa_clid` é omitido em anúncios posicionados no WhatsApp Status. Evidência:
[webhook de texto][text-webhook].

Esses campos viram atribuição de origem. URLs e textos do anúncio são dados
externos não confiáveis: não são buscados pelo backend nem usados como
instrução para a IA. `source_id` e `ctwa_clid` são opacos.

### 8.2 Interativos

Dentro da janela aberta, a Meta permite texto, mídia, contatos, localização e
interativos como CTA URL, lista, solicitação de localização, reply buttons e
Flow. Evidência: [mensagens de serviço][service-messages].

O contrato do MVP envia texto e mídia aprovada. Listas e reply buttons podem
ser adicionados depois de fixtures. A resposta de lista/botão já é aceita pelo
normalizador como inbound, porque o payload está publicado em
[mensagens interativas][interactive-webhook].

### 8.3 WhatsApp Flows

Um Flow concluído retorna no webhook comum como
`interactive.type=nfm_reply`. `response_json` é uma string JSON cuja estrutura
é definida pelo próprio Flow; a resposta não inclui `flow_id`, por isso a Meta
recomenda correlação por `flow_token` ou campo próprio. Flows com endpoint
também possuem protocolo separado de criptografia, assinatura, health check e
eventos operacionais. Evidências: [webhooks de Flows][flows-webhooks] e
[endpoint de Flow][flow-endpoint].

Decisão:

- Instant Forms/Lead Ads continuam sendo o formulário da recuperação oficial
  deste MVP;
- WhatsApp Flows ficam fora do MVP e nunca são confundidos com `page/leadgen`;
- `nfm_reply` é preservado como `flow_reply`, sem qualificação ou automação;
- ativar Flows exige contrato próprio, fixture da conta de teste, correlação
  explícita e validação do protocolo criptográfico.

## 9. Instant Forms e vínculo com a conversa

### 9.1 Ingresso de lead

O webhook de Página usa:

```text
object = page
entry[].changes[].field = leadgen
value.leadgen_id
value.page_id
value.form_id
value.adgroup_id
value.ad_id
value.created_time
```

O webhook é um aviso; respostas não vêm nele. `GET /{LEAD_ID}` retorna
`created_time`, `id`, `ad_id`, `form_id` e `field_data`. Respostas de checkboxes
de aviso legal personalizado são lidas explicitamente por
`custom_disclaimer_responses`. Evidência:
[recuperação de leads][lead-retrieval].

Fluxo:

1. verificar assinatura e persistir `leadgen_id`;
2. deduplicar por `(page_id, leadgen_id)`;
3. buscar o lead com token/permissões próprios;
4. associar `form_id` à versão interna imutável de mapeamento/consentimento;
5. preservar respostas cruas em área privada e produzir valores normalizados;
6. criar/atualizar pré-lead sem esperar WhatsApp;
7. se a conversa chegar primeiro, ela também não espera o formulário.

### 9.2 Vínculo

Não existe ID comum universal publicado entre `leadgen` e
`messages.referral`. O vínculo automático permitido é o telefone exato,
normalizado, do formulário com o telefone do alias Meta, quando ambos
existirem, dentro da mesma organização e com regras de colisão explícitas.
Nunca vincular por nome, e-mail, username, BSUID, `profile.name`, texto de
anúncio ou proximidade temporal: o Instant Form não fornece BSUID para provar
essa relação.

Se o inbound não trouxer telefone ou o contato chamar de outro número, o
vínculo exige revisão humana, conforme a especificação do produto. BSUID,
`wa_id`, telefone e username ficam como aliases versionados da identidade Meta,
não como valores mutuamente deriváveis.

## 10. Consentimento, opt-in e opt-out

### 10.1 Fatos Meta

A Meta exige número móvel fornecido pela pessoa e opt-in para receber
mensagens ou ligações da empresa. Desde a atualização de novembro de 2024, o
opt-in pode ser geral, sem ser específico do WhatsApp, desde que identifique a
empresa, deixe clara a comunicação autorizada e cumpra as leis locais.
Evidência: [guia de opt-in][opt-in].

A política também exige expectativas claras, instruções de opt-out e respeito
a pedidos de interrupção. Evidência:
[WhatsApp Business Messaging Policy][business-policy].

O webhook `user_preferences` informa mudança de preferência de marketing:
`category=marketing_messages` e `value=stop|resume`, com `wa_id` e timestamp.
Evidência: [referência de preferências][user-preferences].

### 10.2 Decisão GrillStudio

O produto adota requisito mais forte que o mínimo Meta para recuperação de
formulário:

```text
ConsentEvidence {
  form_id
  internal_form_version_id
  consent_text_version_id
  published_text_snapshot_hash
  business_identity
  purposes = [real_estate_service, commercial_contact]
  whatsapp_or_mobile_contact_disclosed = true
  opt_out_disclosed = true
  submitted_at
  leadgen_id
  custom_disclaimer_responses?
}
```

Recuperação é bloqueada se a versão/texto publicado não estiver confirmada. Uma
declaração interna, telefone no formulário ou checkbox sem texto versionado não
cria consentimento por si só.

Opt-out:

- pedido textual ou botão de interrupção aplica o bloqueio amplo do produto na
  mesma transação e cancela jobs;
- `user_preferences.value=stop` e erro `131050` também aplicam supressão
  imediata;
- `resume` é registrado como nova evidência, mas não remove automaticamente o
  opt-out organizacional; a retomada segue a decisão humana auditada do
  produto;
- inbound espontâneo após opt-out pode receber resposta dentro da janela, mas
  proativas continuam bloqueadas;
- opt-out sempre é revalidado imediatamente antes do envio.

## 11. Janela de atendimento e recuperação oficial

### 11.1 Janela de atendimento

Uma mensagem ou ligação da pessoa abre uma janela de 24 horas; nova mensagem ou
ligação reinicia o relógio. Dentro dela, service messages de formato livre são
permitidas. Fora dela, somente templates pré-aprovados. Evidência:
[mensagens de serviço][service-messages].

Estado normalizado:

```text
last_qualifying_user_activity_at
customer_service_window_expires_at
window_source = user_message | user_call
```

O MVP atualiza a janela por mensagem, pois ligação não faz parte do produto. Se
o horário for ausente, inválido ou próximo do limite, trata a janela como
fechada. A autorização é recalculada no worker imediatamente antes do envio.

O Free Entry Point de Click-to-WhatsApp é uma regra de preço, não uma extensão
da autorização de formato livre: o usuário abre a janela normal de 24 horas; se
a empresa responder dentro dela, abre uma janela gratuita de 72 horas. Mesmo
com FEP aberto, quando a janela de atendimento fecha só templates podem ser
enviados. Evidência: [preços][pricing].

### 11.2 Fluxos vinculantes

Inbound normal:

```text
mensagem assinada
  -> inbox durável
  -> dedupe por wamid
  -> janela de 24h
  -> conversa presa ao phone_number_id
  -> service message permitida por política
```

Recuperação oficial:

```text
leadgen assinado
  -> leitura do lead
  -> versão de formulário + consentimento confirmados
  -> telefone válido e sem opt-out
  -> conexão oficial escolhida e saudável
  -> template atual APPROVED, idioma e parâmetros válidos
  -> outbox
  -> POST /{phone_number_id}/messages
  -> wamid aceito
  -> receipts
  -> resposta do contato abre janela normal
```

Uma submissão de formulário não abre janela. A mensagem de recuperação é
template mesmo quando enviada segundos depois da submissão.

Categoria da recuperação:

- usar `MARKETING` por padrão para abordagem imobiliária/comercial;
- `UTILITY` só é aceitável se a pessoa solicitou expressamente continuar no
  WhatsApp, o texto é não promocional e específico à solicitação, e a Meta
  aprovou o template nessa categoria;
- a categoria efetiva retornada pela Meta prevalece sobre a categoria pedida.

A categoria conservadora decorre do guia oficial: retargeting e conteúdo para
gerar venda são marketing; “Continue a Conversation on WhatsApp” pode ser
utility apenas quando a pessoa pediu a mudança de canal e o conteúdo cumpre as
restrições. Evidência: [categorização][template-categories].

## 12. Templates

### 12.1 Modelo e sincronização

Templates pertencem à WABA. O contrato de criação contém:

```text
name
category = AUTHENTICATION | MARKETING | UTILITY
language
parameter_format = NAMED | POSITIONAL
components[]
```

Nome usa minúsculas alfanuméricas e underscore; idioma é obrigatório; strings
e variáveis não são traduzidas pela Meta. O mesmo nome pode existir em idiomas
distintos. Evidências: [fundamentos][templates] e
[gerenciamento][template-management].

Sincronização:

```text
GET /{WABA_ID}/message_templates
  ?fields=id,name,language,status,category,parameter_format,components
```

O consumidor percorre paginação, usa `template.id` como chave e guarda
snapshot/hash. Em `message_template_status_update`,
`message_template_quality_update`, `message_template_components_update` ou
`template_category_update`, invalida cache e relê o template.

O webhook de status mostra `message_template_language` com locale separado por
hífen em exemplo, enquanto a API de template/envio usa códigos como `en_US` e
`pt_BR`. Por isso, o vínculo é por template ID; não se faz join primário por
nome+idioma do webhook. Evidências: [status de template][template-status] e
[idiomas][template-languages].

### 12.2 Categorias, componentes e idiomas

Categorias oficiais:

- `MARKETING`: awareness, venda, retargeting, relacionamento e conteúdo misto;
- `UTILITY`: resposta não promocional, específica a ação/solicitação do
  usuário ou crítica;
- `AUTHENTICATION`: OTP e verificação de identidade.

A Meta pode corrigir categoria, inclusive de utility para marketing, e
notifica por webhook. Evidência: [categorização][template-categories].

Os quatro componentes primários são `HEADER`, `BODY`, `FOOTER` e `BUTTONS`;
somente `BODY` é obrigatório. Header pode ser texto, imagem, vídeo, documento
ou localização. Body é texto; footer é opcional; buttons incluem quick reply,
URL e telefone, entre outros. Variáveis precisam de exemplos na criação.
Evidência: [componentes][template-components].

O idioma inicial é `pt_BR`, código oficialmente suportado. A Meta não traduz
conteúdo ou parâmetros. Evidências:
[idiomas suportados][template-languages] e [fundamentos][templates].

### 12.3 Status e regra de envio

O webhook publica eventos como:

```text
APPROVED, ARCHIVED, UNARCHIVED, DELETED, DISABLED, FLAGGED,
IN_APPEAL, LIMIT_EXCEEDED, LOCKED, PAUSED, PENDING,
REINSTATED, PENDING_DELETION, REJECTED
```

Evidência: [status de template][template-status].

Esses são eventos brutos; a regra de capacidade é deliberadamente simples:

```text
can_send = latest_api_status == APPROVED
           && connection_healthy
           && policy_allows
```

Após qualquer evento, reler o template. `PENDING`, `REJECTED`, `PAUSED`,
`DISABLED`, `PENDING_DELETION`, ausência ou estado desconhecido bloqueiam.
`FLAGGED`/qualidade baixa geram alerta e nova leitura; nunca se infere aprovação
só pelo nome do evento.

No envio, o backend:

- seleciona `template_id` sincronizado e usa seu `name` + `language.code`;
- valida quantidade, nomes, ordem e tipos dos parâmetros;
- não deixa a IA alterar literal, categoria, estrutura ou idioma;
- registra template ID, snapshot/hash e parâmetros redigidos na mensagem;
- oferece quick reply de opt-out quando aprovado na versão do template.

## 13. Envio, aceite e resultado incerto

### 13.1 Request e resposta

Todos os envios Cloud API usam:

```text
POST /v26.0/{PHONE_NUMBER_ID}/messages
Authorization: Bearer {server_secret}
Content-Type: application/json

{
  "messaging_product": "whatsapp",
  "recipient_type": "individual",
  "to": "{recipient}",
  "type": "text | image | document | template | ...",
  "{type}": { ... }
}
```

Evidência: [mensagens de serviço][service-messages].

Sucesso retorna a identidade de contato aplicável à versão/conta e
`messages[].id` (`wamid...`). Exemplos tradicionais mostram
`contacts[].input` e `contacts[].wa_id`, mas o parser não os torna
obrigatórios diante do rollout de BSUID. A resposta prova aceite do request,
não entrega; o `wamid` aparece nos webhooks de status. Evidências:
[mensagens de serviço][service-messages] e
[exemplo oficial de texto][send-text], com a evolução documentada em
[BSUID][bsuid].

O comando inclui `biz_opaque_callback_data=<messages.id interno opaco>`, sem
telefone, nome ou outro dado pessoal. Quando fornecido, o valor reaparece no
status. Evidência: [referência de status][status-webhook].

### 13.2 Idempotência

A superfície pública consultada não documenta `Idempotency-Key`, client message
ID com unicidade nem consulta posterior de uma mensagem individual. O
`biz_opaque_callback_data` é correlação, não dedupe.

Fluxo:

1. persistir mensagem + outbox na mesma transação;
2. adquirir `send:{internal_message_id}`;
3. revalidar opt-out, janela, template, número e capacidade;
4. chamar uma vez;
5. em 200, guardar `wamid`;
6. em erro Meta estruturado que prova rejeição, classificar por `code/details`;
7. em timeout, reset de conexão ou 5xx ambíguo, marcar `unknown_outcome`,
   aguardar webhook/correlação e alertar;
8. nunca reenviar resultado incerto sem revisão humana.

A Meta também não garante que a ordem de entrega corresponda à ordem dos
requests; para sequência estrita, é preciso aguardar `delivered` antes do
próximo envio. Evidência: [mensagens de serviço][service-messages].

## 14. Receipts e máquina de estados

Statuses oficiais:

| Raw | Significado |
|---|---|
| `sent` | enviado pelos servidores da Meta |
| `delivered` | entregue ao dispositivo |
| `read` | exibido em conversa aberta |
| `played` | áudio reproduzido pela primeira vez |
| `failed` | falha ao enviar ou entregar |

`read` implica `delivered`; em otimização, a Meta pode omitir o webhook
`delivered` quando ambos acontecem juntos. Uma mensagem pode gerar webhooks
separados. Evidência: [referência de status][status-webhook].

Normalização:

```text
accepted -> sent -> delivered -> read
                              \-> played  # áudio
accepted/sent -> failed
```

- `read` avança diretamente de `accepted`/`sent`;
- `played` não regride `read`;
- `failed` depois de `delivered/read/played` vira anomalia, sem regressão;
- status desconhecido é persistido sem mudar o materializado;
- cada receipt é append-only e o efeito é deduplicado por
  `(connection_id, wamid, status)`.

`conversation` e `pricing` são metadados opcionais. Na v24.0+, `conversation`
pode ser omitido salvo Free Entry Point, e `pricing` aparece apenas em um de
determinados status. Nenhum deles é chave de mensagem, contato ou conversa do
GrillStudio. Evidência: [referência de status][status-webhook].

Falhas outbound trazem `errors[]` com `code`, `title`, `message`,
`error_data.details` e `href`. Erros também podem aparecer em
`value.errors` ou `messages.errors`. Evidências:
[mensagens][messages-webhook] e [status][status-webhook].

## 15. Erros e retry

A Meta orienta construir tratamento em `error.code` e
`error_data.details`, não em título, subcode ou somente HTTP. Erros podem ser
síncronos, assíncronos ou ambos; Graph response e webhook devem ser
monitorados. Evidência: [códigos de erro][errors].

Política inicial:

| Classe | Exemplos oficiais | Decisão |
|---|---|---|
| auth/permissão | `0`, `3`, `10`, `190`, `200`, `131005` | pausar conexão; sem retry |
| integridade/conta | `368`, `130497`, `131031`, `131057` | pausar e alertar dono |
| request/template inválido | `100`, `131008`, `131009`, `132000`, `132001`, `132012`, `132015`, `132016` | não repetir; corrigir estado/template |
| rate/throughput | `4`, `80007`, `130429`, `131056` | backoff com jitter e redução compartilhada |
| temporário estruturado | `1`, `2`, `131000`, `131016`, `133004` | retry limitado só quando a rejeição for inequívoca; caso ambíguo vira `unknown_outcome` |
| janela fechada | `131047` | não repetir free-form; reavaliar template/política |
| proteção/opt-out | `131049`, `131050` | sem retry; 131050 aplica supressão |
| destinatário/entrega | `131026` | sem retry automático |
| mídia | `131052`, `131053` | preservar mensagem; corrigir/solicitar alternativa |

O erro `131049` orienta esperar ao menos 24 horas e pode continuar bloqueado por
período variável; `131050` diz para não tentar de novo porque a pessoa escolheu
parar mensagens de marketing. Evidência: [códigos de erro][errors].

429/limites não autorizam mais volume. Quotas reais de WABA, número, template,
destinatário e app são gates operacionais e não são inferidas dos exemplos.

## 16. Matriz de decisão

| Área | Fato oficial | Contrato GrillStudio | Situação |
|---|---:|---:|---|
| Versão Graph | exemplos atuais `v26.0` | versão explícita e upgrade com fixtures | documental; teste de conta pendente |
| Callback GET | sim | token secreto + challenge | fechado |
| Autenticidade POST | HMAC-SHA256 | raw bytes + timing-safe | fechado; fixture real pendente |
| Retry webhook | até 7 dias, duplicatas | inbox + dedupe | fechado |
| WABA/phone IDs | sim | strings opacas; rota por phone ID | fechado |
| Identidade do participante | BSUID em rollout; telefone/`wa_id` podem faltar | união de aliases + histórico; envio por BSUID desligado | fixture/versionamento pendentes |
| Inbound text/media | sim | envelope normalizado tolerante | fixture pendente |
| Click-to-WhatsApp | `referral` | atribuição, não comando | fechado; placement pendente |
| Instant Form | `leadgen` + GET lead | fluxo independente | formulário teste pendente |
| ID comum form/WhatsApp | não publicado | vínculo só por telefone exato | fechado conservadoramente |
| Janela | 24h após user message/call | revalidar no envio | fechado |
| Free Entry Point | 72h de preço | não estende free-form | fechado |
| Opt-in | número + permissão | evidência versionada mais forte | texto real pendente |
| Opt-out Meta | preference/erro/política | supressão imediata | fechado |
| Templates | categoria/idioma/status/componentes | sync por ID; só APPROVED | conta/template pendentes |
| Idioma | `pt_BR` suportado | português do Brasil | fechado |
| Flow | `nfm_reply` + endpoint próprio documentados | preservar sem efeito; fora do MVP | contrato/fixture próprios pendentes |
| Aceite de envio | retorna `wamid`, não entrega | outbox + receipts | fechado |
| Idempotência de envio | não documentada | não reenviar incerto | gate de produção |
| Receipts | sent/delivered/read/played/failed | monotônico e idempotente | fixture pendente |
| Erros | code/details | classificação conservadora | fechado; amostra real pendente |
| Rate limits | códigos e limites variados | capacidade própria/backoff | valores da conta pendentes |

## 17. Bloqueios e gates de produção

As afirmações seguintes não podem ser comprovadas pela documentação pública sem
uma conta/test number ou ativos de teste:

| Gate | O que falta provar | Aceite objetivo |
|---|---|---|
| Assets e permissões | app, WABA, número, Page, token e App Review realmente autorizados | chamadas read-only e envio sintético funcionam com menor privilégio |
| Callback | assinatura e challenge da configuração concreta | GET válido aceita; token inválido rejeita |
| HMAC | bytes/header reais da Meta e rotação do App Secret | fixture válida aceita; corpo alterado, assinatura inválida/ausente rejeitados |
| Subscription | app inscrito na WABA e Page/leadgen | eventos de teste chegam ao callback esperado |
| Inbound | payload real de texto, contexto, mídia, interativo, edit/revoke e unsupported | fixtures redigidas e sintéticas passam no normalizador |
| Duplicata/batch | retry, lote e evento repetido na configuração concreta | dez entregas geram um único efeito |
| IDs | relação observada entre BSUID, parent BSUID, username, `from`, `wa_id`, phone ID, WABA e `wamid` | aliases persistidos sem heurística; `user_id_update` mantém histórico; rota rejeita WABA/phone divergente |
| BSUID/username | presença e formatos reais na Graph version/conta escolhidas; envio por BSUID ainda em rollout | inbound sem telefone é aceito; outbound por BSUID só habilita após fixture oficial da conta |
| Mídia | upload/download, MIME/hash/tamanho e expiração no número de teste | arquivo sintético permitido é copiado para storage privado; inválido é bloqueado |
| Receipts | ordem, omissões, latência e correlação de status | sent/delivered/read/failed e duplicata não regridem estado |
| Resultado incerto | se webhook chega após timeout de client e se `biz_opaque_callback_data` retorna | não há reenvio duplicado; resultado fica reconciliado ou em revisão |
| Templates | sync, paginação, `pt_BR`, categoria/status/quality e webhooks | mudança para paused/disabled/category bloqueia o próximo envio |
| Recuperação | template comercial real aprovado e parâmetros definidos | somente a versão APPROVED selecionada é enviada ao destinatário sintético |
| Consentimento | texto efetivamente publicado e vínculo à submissão | snapshot/hash/version + resposta de disclaimer comprovam a versão |
| Lead Ads | Page webhook, GET lead, campos reais e formulário tardio | submissão sintética deduplica e preenche somente campos permitidos |
| CTWA | referral por placement e eventual ausência de `ctwa_clid` | fixtures preservam attribution sem depender do campo opcional |
| Opt-out | texto, botão, user preference e `131050` concorrendo com outbox | todos vencem o envio e cancelam jobs antes da chamada |
| Limites | throughput e messaging/template limits concretos da conta | limites/alertas registrados; 429 reduz concorrência |

O acesso mínimo é:

- um app Meta de desenvolvimento;
- uma WABA/número de teste fornecidos pela Meta;
- uma Page e Instant Form de teste, sem publicação para público real;
- identidades sintéticas controladas;
- templates de teste sem nome, telefone, lead ou dado pessoal real;
- segredos efêmeros injetados pelo cofre do executor.

Não são necessários e não devem ser fornecidos: credenciais de produção,
números reais da operação, leads reais, histórico, campanhas, formulários
publicados ou dados pessoais.

Há ainda gates não técnicos:

1. revisão jurídica do texto de consentimento, finalidade comercial e
   opt-out;
2. aprovação do template real e de sua categoria efetiva pela Meta;
3. decisão operacional de capacidade, horários e limites do número;
4. runbook para restrição da conta/template, resultado de envio incerto,
   mídia indisponível e perda de permissão;
5. monitor de drift da versão Graph, política, preço, status/categoria de
   template e qualidade do número.

## 18. Evidência pública reproduzível e segura

As páginas abaixo são públicas e não exigem credenciais:

```bash
curl -fsSL -A 'Mozilla/5.0' \
  'https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/create-webhook-endpoint/?locale=en_US'

curl -fsSL -A 'Mozilla/5.0' \
  'https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/?locale=en_US'

curl -fsSL -A 'Mozilla/5.0' \
  'https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview/?locale=en_US'

curl -fsSL -A 'Mozilla/5.0' \
  'https://developers.facebook.com/documentation/ads-commerce/marketing-api/guides/lead-ads/retrieving?locale=en_US'

curl -fsSL \
  'https://www.whatsappbusiness.com/policy/'
```

Não executar os exemplos `graph.facebook.com` com token até o gate de teste ser
formalmente autorizado. Quando autorizado, usar somente placeholders
sintéticos, redigir request/response e nunca copiar o token para shell history,
arquivo versionado, issue ou chat.

[business-policy]: https://www.whatsappbusiness.com/policy/
[bsuid]: https://developers.facebook.com/documentation/business-messaging/whatsapp/business-scoped-user-ids/
[errors]: https://developers.facebook.com/documentation/business-messaging/whatsapp/support/error-codes
[flow-endpoint]: https://developers.facebook.com/documentation/business-messaging/whatsapp/flows/guides/implementingyourflowendpoint/
[flows-webhooks]: https://developers.facebook.com/documentation/business-messaging/whatsapp/flows/guides/flowswebhooks/
[interactive-webhook]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/interactive/
[lead-retrieval]: https://developers.facebook.com/documentation/ads-commerce/marketing-api/guides/lead-ads/retrieving
[media]: https://developers.facebook.com/documentation/business-messaging/whatsapp/business-phone-numbers/media/
[messages-webhook]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/
[opt-in]: https://developers.facebook.com/documentation/business-messaging/whatsapp/getting-opt-in/
[phone-numbers]: https://www.postman.com/meta/whatsapp-business-platform/request/e9ady51/get-phone-numbers
[pricing]: https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing/
[send-text]: https://www.postman.com/meta/whatsapp-business-platform/request/8gvd47s/send-text-message
[service-messages]: https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages/
[status-webhook]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/status/
[template-categories]: https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/template-categorization/
[template-components]: https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/components/
[template-languages]: https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/supported-languages/
[template-management]: https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/template-management/
[template-status]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/message_template_status_update/
[templates]: https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview/
[text-webhook]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/text/
[user-preferences]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/user_preferences/
[waba-subscription]: https://www.postman.com/meta/whatsapp-business-platform/documentation/du6gzjv/embedded-signup?entity=request-13382743-a0ad59ca-6258-48fa-8662-98ecd381fec9
[webhook-endpoint]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/create-webhook-endpoint/
[webhooks]: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview/
